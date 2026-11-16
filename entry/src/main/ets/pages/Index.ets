import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { AudioMeterService, MeterState } from '../meter/AudioMeterService';
import { MeterReading, DB_FLOOR } from '../meter/LevelMeter';
import { MeterScale } from '../meter/MeterScale';

// Wearable: 10 fps is plenty on a small screen and saves battery.
// Peak-hold still catches every transient inside each 100 ms window.
const UI_INTERVAL_MS: number = 100;
const MIC: Permissions = 'ohos.permission.MICROPHONE';

// 270° gauge with the gap at the bottom (where the button sits).
const ARC_START: number = Math.PI * 0.75;  // 135°
const ARC_SWEEP: number = Math.PI * 1.5;   // 270°
const STROKE: number = 14;                 // px

@Entry
@Component
struct Index {
  private service: AudioMeterService = new AudioMeterService();
  private mScale: MeterScale = new MeterScale(-60, 0);
  private timerId: number = -1;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  @State running: boolean = false;
  @State paused: boolean = false; // audio focus temporarily lost
  @State status: string = 'Tap to start';
  @State levelDb: number = DB_FLOOR;
  @State peakDb: number = DB_FLOOR;

  // Don't keep the mic open (and drain the battery) when the page is hidden.
  onPageHide(): void {
    this.stopMeter();
  }

  aboutToDisappear(): void {
    this.stopMeter();
  }

  private async requestMic(): Promise<boolean> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const atManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(ctx, [MIC]);
    return result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }

  private async startMeter(): Promise<void> {
    try {
      if (!(await this.requestMic())) {
        this.status = 'No mic permission';
        return;
      }
      this.service.onStateChange = (state: MeterState) => this.onServiceState(state);
      await this.service.start();
      this.running = true;
      this.paused = false;
      this.status = '';
      this.timerId = setInterval(() => this.tick(), UI_INTERVAL_MS);
    } catch (e) {
      this.status = 'Start failed';
    }
  }

  private async stopMeter(): Promise<void> {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    await this.service.stop();
    this.running = false;
    this.paused = false;
    this.levelDb = DB_FLOOR;
    this.peakDb = DB_FLOOR;
    this.status = 'Tap to start';
    this.draw();
  }

  // Audio focus changes reported by the service.
  private onServiceState(state: MeterState): void {
    switch (state) {
      case MeterState.RUNNING:
        this.paused = false;
        this.status = '';
        break;
      case MeterState.PAUSED:
        this.paused = true;
        this.status = 'Paused by another app';
        this.levelDb = DB_FLOOR;
        this.peakDb = DB_FLOOR;
        this.draw();
        break;
      case MeterState.STOPPED:
        if (this.timerId !== -1) {
          clearInterval(this.timerId);
          this.timerId = -1;
        }
        this.running = false;
        this.paused = false;
        this.levelDb = DB_FLOOR;
        this.peakDb = DB_FLOOR;
        this.status = 'Mic taken by another app';
        this.draw();
        break;
      default:
        break;
    }
  }

  private tick(): void {
    if (this.paused) {
      return; // no frames arrive while paused
    }
    const r: MeterReading = this.service.read(); // also closes the peak interval
    this.levelDb = r.smoothedDb;
    this.peakDb = r.peakDb;
    this.draw();
  }

  // ---------- drawing (UI scaling only; input is already dBFS) ----------

  private arc(cx: number, cy: number, r: number, from: number, to: number,
              color: string, cap: CanvasLineCap): void {
    this.ctx.beginPath();
    this.ctx.arc(cx, cy, r, from, to);
    this.ctx.strokeStyle = color;
    this.ctx.lineWidth = STROKE;
    this.ctx.lineCap = cap;
    this.ctx.stroke();
  }

  private draw(): void {
    const w = this.ctx.width;
    const h = this.ctx.height;
    const cx = w / 2;
    const cy = h / 2;
    const r = Math.min(w, h) / 2 - STROKE; // hug the round bezel

    this.ctx.clearRect(0, 0, w, h);

    // Track
    this.arc(cx, cy, r, ARC_START, ARC_START + ARC_SWEEP, '#262626', 'round');

    // Level (EMA-smoothed RMS)
    const levelFrac = this.mScale.toFraction(this.levelDb);
    if (levelFrac > 0) {
      this.arc(cx, cy, r, ARC_START, ARC_START + levelFrac * ARC_SWEEP,
        this.mScale.colorFor(this.levelDb), 'round');
    }

    // Peak-hold tick
    const peakFrac = this.mScale.toFraction(this.peakDb);
    if (this.running && !this.paused && peakFrac > 0) {
      const a = ARC_START + peakFrac * ARC_SWEEP;
      this.arc(cx, cy, r, a - 0.025, a + 0.025, '#FFFFFF', 'butt');
    }
  }

  build() {
    Stack() {
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .onReady(() => this.draw())

      Column({ space: 2 }) {
        Text(this.running && !this.paused ? this.mScale.label(this.levelDb) : '--')
          .fontSize(40)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
        Text('dBFS').fontSize(14).fontColor('#9E9E9E')
        Text(`PK ${this.running && !this.paused ? this.mScale.label(this.peakDb) : '--'}`)
          .fontSize(14)
          .fontColor('#BDBDBD')
          .margin({ top: 6 })
        if (this.status.length > 0) {
          Text(this.status).fontSize(12).fontColor('#757575').margin({ top: 4 })
        }
      }

      // Start/Stop sits in the bottom gap of the arc
      Button(this.running ? 'Stop' : 'Start')
        .height(36)
        .width(84)
        .fontSize(14)
        .backgroundColor(this.running ? '#B71C1C' : '#1B5E20')
        .position({ x: '50%', y: '82%' })
        .translate({ x: -42, y: -18 })
        .onClick(() => {
          if (this.running) {
            this.stopMeter();
          } else {
            this.startMeter();
          }
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black) // OLED-friendly
  }
}
