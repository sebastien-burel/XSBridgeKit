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
  run() {
    return this.#counter++;
  }
}
