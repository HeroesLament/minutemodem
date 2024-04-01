//! Slab allocator for channel storage
//!
//! Provides O(1) insert/lookup/remove with stable IDs.
//! Uses per-slot locks for concurrent access to different channels.

use std::sync::{Mutex, RwLock};

/// Slot containing a channel with its own lock
pub struct ChannelSlot<T> {
    /// The channel data, protected by its own mutex
    pub data: Mutex<Option<T>>,
}

impl<T> ChannelSlot<T> {
    fn new() -> Self {
        Self {
            data: Mutex::new(None),
        }
    }
    
    fn new_with(item: T) -> Self {
        Self {
            data: Mutex::new(Some(item)),
        }
    }
}

/// Slab allocator with per-channel locking
/// 
/// Structure access (insert/remove) requires write lock on slab metadata.
/// Channel access (get/get_mut) only locks the individual slot.
pub struct ChannelSlab<T> {
    /// Storage slots - each slot has its own lock
    slots: Vec<ChannelSlot<T>>,
    
    /// Metadata protected by RwLock
    /// (free list, id mapping, next_id)
    meta: RwLock<SlabMeta>,
}

struct SlabMeta {
    /// Free list (indices of available slots)
    free: Vec<usize>,
    
    /// Next ID to assign (monotonically increasing)
    next_id: u64,
    
    /// Map from external ID to internal slot index
    id_to_slot: std::collections::HashMap<u64, usize>,
}

impl<T> ChannelSlab<T> {
    pub fn new(capacity: usize) -> Self {
        let mut slots = Vec::with_capacity(capacity);
        for _ in 0..capacity {
            slots.push(ChannelSlot::new());
        }
        let free: Vec<usize> = (0..capacity).rev().collect();
        
        Self {
            slots,
            meta: RwLock::new(SlabMeta {
                free,
                next_id: 0,
                id_to_slot: std::collections::HashMap::new(),
            }),
        }
    }
    
    /// Insert an item, returns its ID or None if full
    /// Requires write lock on metadata
    pub fn insert(&self, item: T) -> Option<u64> {
        let mut meta = self.meta.write().ok()?;
        
        let slot_idx = meta.free.pop()?;
        
        let id = meta.next_id;
        meta.next_id += 1;
        
        // Lock the specific slot and insert
        let mut slot_data = self.slots[slot_idx].data.lock().ok()?;
        *slot_data = Some(item);
        drop(slot_data);
        
        meta.id_to_slot.insert(id, slot_idx);
        
        Some(id)
    }
    
    /// Get slot index for an ID (only needs read lock on metadata)
    fn get_slot_idx(&self, id: u64) -> Option<usize> {
        let meta = self.meta.read().ok()?;
        meta.id_to_slot.get(&id).copied()
    }
    
    /// Execute a function with mutable access to a channel
    /// Only locks the specific channel's slot, not the whole slab
    pub fn with_channel_mut<F, R>(&self, id: u64, f: F) -> Option<R>
    where
        F: FnOnce(&mut T) -> R,
    {
        let slot_idx = self.get_slot_idx(id)?;
        let mut slot_data = self.slots[slot_idx].data.lock().ok()?;
        let channel = slot_data.as_mut()?;
        Some(f(channel))
    }
    
    /// Execute a function with read access to a channel
    pub fn with_channel<F, R>(&self, id: u64, f: F) -> Option<R>
    where
        F: FnOnce(&T) -> R,
    {
        let slot_idx = self.get_slot_idx(id)?;
        let slot_data = self.slots[slot_idx].data.lock().ok()?;
        let channel = slot_data.as_ref()?;
        Some(f(channel))
    }
    
    /// Remove an item by ID
    /// Requires write lock on metadata
    pub fn remove(&self, id: u64) -> Option<T> {
        let mut meta = self.meta.write().ok()?;
        
        let slot_idx = meta.id_to_slot.remove(&id)?;
        
        // Lock the specific slot and remove
        let mut slot_data = self.slots[slot_idx].data.lock().ok()?;
        let item = slot_data.take()?;
        drop(slot_data);
        
        meta.free.push(slot_idx);
        Some(item)
    }
    
    /// Get the number of active items
    pub fn count(&self) -> usize {
        self.meta.read().map(|m| m.id_to_slot.len()).unwrap_or(0)
    }
}

// Make ChannelSlab safe to share across threads
unsafe impl<T: Send> Sync for ChannelSlab<T> {}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_slab_insert_get() {
        let slab: ChannelSlab<i32> = ChannelSlab::new(10);
        
        let id = slab.insert(42).unwrap();
        assert_eq!(slab.count(), 1);
        
        let result = slab.with_channel(id, |v| *v);
        assert_eq!(result, Some(42));
    }
    
    #[test]
    fn test_slab_remove() {
        let slab: ChannelSlab<i32> = ChannelSlab::new(10);
        
        let id = slab.insert(42).unwrap();
        assert_eq!(slab.count(), 1);
        
        slab.remove(id);
        assert_eq!(slab.count(), 0);
        assert!(slab.with_channel(id, |v| *v).is_none());
    }
    
    #[test]
    fn test_slab_reuse() {
        let slab: ChannelSlab<i32> = ChannelSlab::new(2);
        
        let id1 = slab.insert(1).unwrap();
        let _id2 = slab.insert(2).unwrap();
        
        // Slab is full
        assert!(slab.insert(3).is_none());
        
        // Remove one
        slab.remove(id1);
        
        // Can insert again
        let id3 = slab.insert(3).unwrap();
        assert!(id3 != id1); // New ID even though slot reused
        
        assert_eq!(slab.count(), 2);
    }
    
    #[test]
    fn test_concurrent_access() {
        use std::thread;
        use std::sync::Arc;
        
        let slab: Arc<ChannelSlab<i32>> = Arc::new(ChannelSlab::new(100));
        
        // Insert some items
        let ids: Vec<u64> = (0..10).map(|i| slab.insert(i).unwrap()).collect();
        
        // Spawn threads that access different channels concurrently
        let handles: Vec<_> = ids.iter().map(|&id| {
            let slab = Arc::clone(&slab);
            thread::spawn(move || {
                for _ in 0..1000 {
                    slab.with_channel_mut(id, |v| *v += 1);
                }
            })
        }).collect();
        
        for h in handles {
            h.join().unwrap();
        }
        
        // Each channel should have been incremented 1000 times
        for (i, &id) in ids.iter().enumerate() {
            let val = slab.with_channel(id, |v| *v).unwrap();
            assert_eq!(val, i as i32 + 1000);
        }
    }
}