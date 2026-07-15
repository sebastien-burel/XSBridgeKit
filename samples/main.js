import { Counter } from "./tools.js";

globalThis.counter = new Counter();

export default (count) => {
  if (count) counter.count = count;
  print(`Start: ${counter.run()}`);
}
