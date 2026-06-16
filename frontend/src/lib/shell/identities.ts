// Agent identities — each harness owns a hue, used for its avatar and role tag.
// Kept distinct from the accent and from each other (see design system §7).

export interface AgentIdentity {
	/** harness id */
	id: string;
	/** short role tag, e.g. CC / H / OC */
	tag: string;
	/** human label */
	label: string;
	/** CSS custom property holding the identity hue */
	colorVar: string;
}

const IDENTITIES: Record<string, AgentIdentity> = {
	claude_code: { id: 'claude_code', tag: 'CC', label: 'Claude Code', colorVar: '--claude' },
	hermes: { id: 'hermes', tag: 'H', label: 'Hermes', colorVar: '--hermes' },
	// OpenClaw is design-only today, but kept here so a future harness lands themed.
	openclaw: { id: 'openclaw', tag: 'OC', label: 'OpenClaw', colorVar: '--openclaw' }
};

export function identityFor(harnessId: string): AgentIdentity {
	return (
		IDENTITIES[harnessId] ?? {
			id: harnessId,
			tag: harnessId.slice(0, 2).toUpperCase(),
			label: harnessId,
			colorVar: '--legend'
		}
	);
}

/** The human "speaker" identity used in composers / YOU role tags. */
export const HUMAN: AgentIdentity = {
	id: 'human',
	tag: 'YOU',
	label: 'You',
	colorVar: '--accent-hi'
};
