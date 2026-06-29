# Project Instructions

- **Default Audio Format:** The default audio format for processed recordings is **WAV**, not M4A. Ensure any logic assuming a default format respects this.
- **Processing Flow:** "Recover to Recording" bypasses VAD to force-process discarded audio.
- **Workflow Requirement:** Before modifying any code, conduct in-depth research, present findings along with proposed code changes, and ask for explicit approval from the user before making edits.

## Research & Reasoning Depth (Always On)

- Before answering anything non-trivial, state your plan: what you will check and why
- Use a minimum of 2 independent tool calls to verify any claim — never answer from a single source
- Read ALL relevant files before writing or concluding — never assume structure, imports, or dependencies
- Think step by step. Show your reasoning, not just your conclusion
- After completing, audit your own response: flag any assumption that wasn't directly verified
- Never truncate reasoning to save tokens — depth is more valuable than speed here
- If uncertain, say so explicitly with why — do not silently guess
- For complex tasks, break into sub-problems and solve each before synthesizing
