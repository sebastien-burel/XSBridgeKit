export class Tool {

  get description() {
    return ""
  }

  execute() {

  }
}


export class Counter extends Tool {
  #counter;

  constructor() {
    super();
    this.#counter = 0;
  }
  set count (counter) {
    this.#counter = counter;
  }
  run() {
    return this.#counter++;
  }
}
