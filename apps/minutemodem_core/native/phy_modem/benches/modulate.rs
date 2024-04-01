//! Modulation benchmarks

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use phy_modem::*;

fn benchmark_psk8_modulate(c: &mut Criterion) {
    let timing = FixedTiming::new(9600, 2400);
    let pulse = RootRaisedCosine::default_for_sps(timing.samples_per_symbol());
    let carrier = Nco::new(1800.0, 9600);
    let mut modulator = Modulator::new(Psk8, pulse, carrier, timing);

    let symbols: Vec<u8> = (0..1000).map(|i| (i % 8) as u8).collect();

    c.bench_function("psk8_modulate_1000_symbols", |b| {
        b.iter(|| {
            modulator.reset();
            black_box(modulator.modulate(&symbols))
        })
    });
}

fn benchmark_qam64_modulate(c: &mut Criterion) {
    let timing = FixedTiming::new(9600, 2400);
    let pulse = RootRaisedCosine::default_for_sps(timing.samples_per_symbol());
    let carrier = Nco::new(1800.0, 9600);
    let mut modulator = Modulator::new(Qam64, pulse, carrier, timing);

    let symbols: Vec<u8> = (0..1000).map(|i| (i % 64) as u8).collect();

    c.bench_function("qam64_modulate_1000_symbols", |b| {
        b.iter(|| {
            modulator.reset();
            black_box(modulator.modulate(&symbols))
        })
    });
}

criterion_group!(benches, benchmark_psk8_modulate, benchmark_qam64_modulate);
criterion_main!(benches);