import type { HueAmbienceFrame } from './hueAmbienceFrames.js';
import { buildHueLightBody, buildHueLightOffBody } from './hueRenderer.js';
import type { HueLightClient } from './hueTypes.js';

export interface HueAmbienceRenderer {
  render(frame: HueAmbienceFrame): Promise<void>;
  stop(frame: HueAmbienceFrame): Promise<void>;
}

export class ClipHueAmbienceRenderer implements HueAmbienceRenderer {
  constructor(private readonly client: HueLightClient) {}

  async render(frame: HueAmbienceFrame): Promise<void> {
    for (const target of frame.targets) {
      for (const lightFrame of target.lights) {
        await this.client.updateLight(
          lightFrame.light.id,
          buildHueLightBody(lightFrame.light, lightFrame.colors, frame.transitionSeconds),
        );
      }
    }
  }

  async stop(frame: HueAmbienceFrame): Promise<void> {
    for (const target of frame.targets) {
      for (const lightFrame of target.lights) {
        await this.client.updateLight(lightFrame.light.id, buildHueLightOffBody());
      }
    }
  }
}
