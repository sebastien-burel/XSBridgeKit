// Phase 6 module: static `import ... from` with a `./` specifier — proves
// module-goal parsing and importer-relative resolution, not just import().
import { answer } from './answer.js';
export const doubled = answer * 2;
