/**
 * Measurement layer: works only in dBFS, knows nothing about the UI.
 *
 * dBFS reference: digital full scale = 1.0 (int16 sample / 32768).
 * A full-scale square wave reads 0 dBFS; a full-scale sine reads -3.01 dBFS
 * (plain RMS convention, no AES-17 +3 dB offset).
 */

export const DB_FLOOR: number = -120;           // reported for silence
const MS_FLOOR: number = Math.pow(10, DB_FLOOR / 10); // mean-square at the floor

/** Mean of squared, normalized samples (mono int16 PCM). */
export function meanSquare(samples: Int16Array): number {
  const n = samples.length;
  if (n === 0) {
    return 0;
  }
  let sum = 0;
  for (let i = 0; i < n; i++) {
    const s = samples[i] / 32768;
    sum += s * s;
  }
  return sum / n;
}

/** 20*log10(rms) == 10*log10(meanSquare) – avoids a sqrt. */
export function meanSquareToDbfs(ms: number): number {
  return 10 * Math.log10(Math.max(ms, MS_FLOOR));
}

/** Convenience: RMS level of one PCM frame in dBFS. */
export function rmsDbfs(samples: Int16Array): number {
  return meanSquareToDbfs(meanSquare(samples));
}

/**
 * Exponential moving average with a time constant instead of a fixed alpha,
 * so smoothing behaves the same no matter how large the capture buffers are.
 *   alpha = 1 - exp(-dt / tau)
 */
export class EmaSmoother {
  private tauSec: number;
  private value: number = 0;
  private initialized: boolean = false;

  constructor(tauSec: number) {
    this.tauSec = tauSec;
  }

  update(x: number, dtSec: number): number {
    if (!this.initialized) {
      this.value = x;
      this.initialized = true;
    } else {
      const alpha = 1 - Math.exp(-dtSec / this.tauSec);
      this.value += alpha * (x - this.value);
    }
    return this.value;
  }

  reset(): void {
    this.value = 0;
    this.initialized = false;
  }
}

/**
 * Holds the highest value seen since the last read.
 * Audio frames arrive much faster than the UI refreshes; without this,
 * short transients between two UI ticks would never be displayed.
 */
export class IntervalPeakHold {
  private peak: number = DB_FLOOR;
  private hasData: boolean = false;
  private lastEmitted: number = DB_FLOOR;

  push(db: number): void {
    if (!this.hasData || db > this.peak) {
      this.peak = db;
    }
    this.hasData = true;
  }

  /** Returns the interval's peak and starts a new interval. */
  takeAndReset(): number {
    if (this.hasData) {
      this.lastEmitted = this.peak;
    }
    this.hasData = false;
    this.peak = DB_FLOOR;
    return this.lastEmitted; // no new frames -> repeat last value instead of dropping
  }

  reset(): void {
    this.peak = DB_FLOOR;
    this.lastEmitted = DB_FLOOR;
    this.hasData = false;
  }
}

export interface MeterReading {
  rmsDb: number;      // latest raw frame RMS
  smoothedDb: number; // EMA-smoothed RMS
  peakDb: number;     // max frame RMS since previous read()
}

/** Combines the three pieces. Feed frames in, read once per UI tick. */
export class LevelMeter {
  private sampleRate: number;
  private ema: EmaSmoother;
  private peakHold: IntervalPeakHold = new IntervalPeakHold();
  private lastRmsDb: number = DB_FLOOR;
  private smoothedDb: number = DB_FLOOR;

  constructor(sampleRate: number, tauSec: number) {
    this.sampleRate = sampleRate;
    this.ema = new EmaSmoother(tauSec);
  }

  processFrame(samples: Int16Array): void {
    if (samples.length === 0) {
      return;
    }
    const ms = meanSquare(samples);
    const dtSec = samples.length / this.sampleRate;

    // Smooth in the power domain (physically correct), convert to dB afterwards.
    const smoothedMs = this.ema.update(ms, dtSec);

    this.lastRmsDb = meanSquareToDbfs(ms);
    this.smoothedDb = meanSquareToDbfs(smoothedMs);
    this.peakHold.push(this.lastRmsDb);
  }

  read(): MeterReading {
    const reading: MeterReading = {
      rmsDb: this.lastRmsDb,
      smoothedDb: this.smoothedDb,
      peakDb: this.peakHold.takeAndReset()
    };
    return reading;
  }

  reset(): void {
    this.ema.reset();
    this.peakHold.reset();
    this.lastRmsDb = DB_FLOOR;
    this.smoothedDb = DB_FLOOR;
  }
}
