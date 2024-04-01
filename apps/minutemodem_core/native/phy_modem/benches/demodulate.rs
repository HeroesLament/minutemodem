//! Demodulation benchmarks

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use phy_modem::*;

fn benchmark_psk8_demodulate(c: &mut Criterion) {
    // First generate some test samples
    let timing = FixedTiming::new(9600, 2400);
    let pulse = RootRaisedCosine::default_for_sps(timing.samples_per_symbol());
    let carrier = Nco::new(1800.0, 9600);
    let mut modulator = Modulator::new(Psk8, pulse.clone(), carrier.clone(), timing);

    let symbols: Vec<u8> = (0..1000).map(|i| (i % 8) as u8).collect();
    let samples = modulator.modulate(&symbols);

    let pulse2 = RootRaisedCosine::default_for_sps(timing.samples_per_symbol());
    let carrier2 = Nco::new(1800.0, 9600);
    let mut demodulator = Demodulator::new(Psk8, pulse2, carrier2, timing);

    c.bench_function("psk8_demodulate_1000_symbols", |b| {
        b.iter(|| {
            demodulator.reset();
            black_box(demodulator.demodulate(&samples))
        })
    });
}

fn benchmark_qam64_demodulate(c: &mut Criterion) {
    let timing = FixedTiming::new(9600, 2400);
    let pulse = RootRaisedCosine::default_for_sps(timing.samples_per_symbol());
    let carrier = Nco::new(1800.0, 9600);
    let mut modulator = Modulator::new(Qam64, pulse.clone(), carrier.clone(), timing);

    let symbols: Vec<u8> = (0..1000).map(|i| (i % 64) as u8).collect();
    let samples = modulator.modulate(&symbols);

    let pulse2 = RootRaisedCosine::default_for_sps(timing.samples_per_symbol());
    let carrier2 = Nco::new(1800.0, 9600);
    let mut demodulator = Demodulator::new(Qam64, pulse2, carrier2, timing);

    c.bench_function("qam64_demodulate_1000_symbols", |b| {
        b.iter(|| {
            demodulator.reset();
            black_box(demodulator.demodulate(&samples))
        })
    });
}

criterion_group!(benches, benchmark_psk8_demodulate, benchmark_qam64_demodulate);
criterion_main!(benches);