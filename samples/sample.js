import { hello, goodbye, breakit, counter } from "./modules.xsb";

print('Now=' + getCurrentTime());

(async () => {
  print(`C1: ${counter()}`);
})();

(async () => {
  print(`C2: ${counter()}`);
})();

(async () => {
  print(`C3: ${counter()}`);
})();


debugger;
