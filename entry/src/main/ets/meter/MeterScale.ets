/**
 * Presentation layer: turns dBFS into something drawable.
 * Change the display range or colors here without touching the measurement.
 */
export class MeterScale {
  readonly minDb: number;
  readonly maxDb: number;

  constructor(minDb: number = -60, maxDb: number = 0) {
    this.minDb = minDb;
    this.maxDb = maxDb;
  }

  /** Linear-in-dB mapping to 0..1, clamped. */
  toFraction(db: number): number {
    const f = (db - this.minDb) / (this.maxDb - this.minDb);
    return Math.min(1, Math.max(0, f));
  }

  colorFor(db: number): string {
    if (db >= -6) {
      return '#E53935'; // hot
    }
    if (db >= -18) {
      return '#FDD835'; // loud
    }
    return '#43A047';   // normal
  }

  label(db: number): string {
    return db <= this.minDb ? `< ${this.minDb}` : db.toFixed(1);
  }
}
