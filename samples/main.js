import { Counter } from "./tools.js";

global.counter = new Counter();

export default () => {
  print(`Start: ${counter.run()}`);
}
