export const hello = (lang) => `Dis bonjour en ${lang}.`;
export const goodbye = (lang) => `Dis au revoir en ${lang}.`;
export const breakit = (lang) => {
  debugger
  return `Dis au revoir en ${lang}.`
};


function buildF() {
  let counter = 0;
  return () => counter++;
}

export const counter = buildF();
