These rules apply to any content intended to be consumed by AI agents rather than humans. This includes AGENTS.md files and any files under the `.agents/` directory. Follow progressive disclosure principles.

# Formatting Rules

- Do not start content with a heading. Lead with a sentence or two of plain prose that describes the purpose of the file.
- Use H1 (`#`) for each major section. Multiple H1 headings per file are expected and correct — do not consolidate them under a single top-level heading.
- Use H2 (`##`) for subsections within a major section.

# Authoring Rules

Apply these steps whenever writing or updating AI-consumed content — whether creating a new file or editing an existing one.

1. **Make any requested changes first** (when editing an existing file).

2. **Find contradictions**: Identify any instructions that conflict with each other. For each contradiction, ask which version to keep.

3. **Identify the essentials**: Extract only what belongs in the root AGENTS.md:
   - One-sentence project description
   - Package manager (if not npm)
   - Non-standard build/typecheck commands
   - Anything truly relevant to every single task

4. **Group the rest**: Organize remaining instructions into logical categories (e.g., TypeScript conventions, testing patterns, API design, Git workflow). For each group, create or update a separate markdown file under `.agents/`.

5. **Create or update the file structure**:
   - A minimal root AGENTS.md with markdown links to the separate files
   - Each separate file with its relevant instructions

6. **Remove duplication**: Ensure each rule has a single source of truth. Merge or remove any content that says the same thing in two places, even if the wording differs.

7. **Flag for deletion**: Identify any instructions that are:
   - Redundant (the agent already knows this)
   - Too vague to be actionable
   - Overly obvious (like "write clean code")