import { Counter } from "./tools.js";

globalThis.counter = new Counter();

export default () => {
  print(`Start: ${counter.run()}`);
}
