import { audio } from '@kit.AudioKit';
import { LevelMeter, MeterReading } from './LevelMeter';

export const SAMPLE_RATE: number = 48000;
const EMA_TAU_SEC: number = 0.3; // ~300 ms, typical VU-ish ballistics

export enum MeterState {
  RUNNING,
  PAUSED,   // focus lost temporarily, e.g. an incoming call
  STOPPED   // focus lost permanently
}

export class AudioMeterService {
  private meter: LevelMeter = new LevelMeter(SAMPLE_RATE, EMA_TAU_SEC);
  private capturer: audio.AudioCapturer | null = null;

  /** Notifies the UI when audio focus changes the capture state. */
  onStateChange: ((state: MeterState) => void) | null = null;

  async start(): Promise<void> {
    if (this.capturer !== null) {
      return;
    }
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
      channels: audio.AudioChannel.CHANNEL_1,                 // mono -> no de-interleaving
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };

    const c = await audio.createAudioCapturer(options);
    c.on('readData', (buffer: ArrayBuffer) => {
      // 2 bytes per S16LE sample; ignore a trailing odd byte if any.
      const frame = new Int16Array(buffer, 0, buffer.byteLength >> 1);
      this.meter.processFrame(frame);
    });
    // Audio focus: react when another stream (call, alarm, voice assistant) takes the mic.
    c.on('audioInterrupt', (event: audio.InterruptEvent) => {
      this.handleInterrupt(event);
    });
    await c.start();
    this.capturer = c;
  }

  /** User-initiated stop. Does not fire onStateChange. */
  async stop(): Promise<void> {
    await this.releaseCapturer();
  }

  /** Called once per UI tick. Also resets the interval peak. */
  read(): MeterReading {
    return this.meter.read();
  }

  private handleInterrupt(event: audio.InterruptEvent): void {
    if (event.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
      // The system has already paused/stopped the stream. We only sync our state.
      switch (event.hintType) {
        case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
          this.meter.reset(); // don't show stale levels while paused
          this.notify(MeterState.PAUSED);
          break;
        case audio.InterruptHint.INTERRUPT_HINT_STOP:
          // Focus lost for good: no RESUME will follow, so free the capturer.
          this.releaseCapturer().then(() => this.notify(MeterState.STOPPED));
          break;
        default:
          break;
      }
    } else if (event.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
      // The system leaves these to the app. RESUME arrives after a temporary pause ends.
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
        this.resume();
      }
    }
  }

  private async resume(): Promise<void> {
    const c = this.capturer;
    if (c === null) {
      return;
    }
    try {
      await c.start();
      this.notify(MeterState.RUNNING);
    } catch (e) {
      await this.releaseCapturer();
      this.notify(MeterState.STOPPED);
    }
  }

  private async releaseCapturer(): Promise<void> {
    const c = this.capturer;
    if (c === null) {
      return;
    }
    this.capturer = null;
    c.off('readData');
    c.off('audioInterrupt');
    try {
      if (c.state === audio.AudioState.STATE_RUNNING) {
        await c.stop();
      }
    } catch (e) {
      console.error(`Couldn't stop audio ${e}`)
    }
    try {
      await c.release();
    } catch (e) {
      console.error(`Relase failed ${e}`)
    }
    this.meter.reset();
  }

  private notify(state: MeterState): void {
    if (this.onStateChange !== null) {
      this.onStateChange(state);
    }
  }
}
