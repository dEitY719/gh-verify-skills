/**
 * gh-verify plugin for OpenCode.ai
 *
 * Auto-registers the skills directory via the config hook (no symlinks needed).
 *
 * Like the sibling harness and notes plugins, this one injects no per-session
 * bootstrap context. The gh-verify skills are task-triggered — you reach for one
 * when a specific pull request needs reviewing or verifying — so OpenCode's
 * native `skill` tool discovering them is all that is needed.
 */

import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const GhVerifyPlugin = async () => {
  const ghVerifySkillsDir = path.resolve(__dirname, '../../skills');

  return {
    // Inject skills path into live config so OpenCode discovers gh-verify
    // skills without requiring manual symlinks or config file edits.
    // This works because Config.get() returns a cached singleton — modifications
    // here are visible when skills are lazily discovered later.
    config: async (config) => {
      config.skills = config.skills || {};
      config.skills.paths = config.skills.paths || [];
      if (!config.skills.paths.includes(ghVerifySkillsDir)) {
        config.skills.paths.push(ghVerifySkillsDir);
      }
    },
  };
};
