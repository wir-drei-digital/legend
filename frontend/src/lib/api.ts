import { PUBLIC_API_URL } from '$env/static/public';

export const apiBase = PUBLIC_API_URL || '';

export async function getHealth(): Promise<{ status: string }> {
	const res = await fetch(`${apiBase}/api/health`);
	if (!res.ok) throw new Error(`health check failed: ${res.status}`);
	return res.json();
}
