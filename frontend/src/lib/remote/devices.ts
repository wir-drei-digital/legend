import { apiFetch } from '$lib/api';

async function fail(res: Response, fallback: string): Promise<never> {
	let detail = `${res.status}`;
	try {
		detail = (await res.json()).error ?? detail;
	} catch {
		// keep status code
	}
	throw new Error(`${fallback}: ${detail}`);
}

export interface PairResult {
	token: string;
	device: { id: string; name: string | null };
}

/** Redeem a pairing code (public, pre-auth). The instance mints a device token. */
export async function redeemPairCode(code: string, name?: string): Promise<PairResult> {
	const res = await apiFetch('/api/pair', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ code, name })
	});
	if (!res.ok) await fail(res, 'pairing failed');
	return res.json();
}
