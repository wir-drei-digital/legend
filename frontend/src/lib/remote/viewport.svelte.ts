// Reactive narrow-viewport flag: phones get MobileShell, desktops LegendShell.
// SSR is off, so window is available at first client render — no flash. A live
// matchMedia listener flips it when a desktop window is resized (also makes it
// trivially testable by narrowing the window).
const QUERY = '(max-width: 760px)';

function createIsMobile() {
	let matches = $state(false);
	if (typeof window !== 'undefined' && typeof window.matchMedia === 'function') {
		const mql = window.matchMedia(QUERY);
		matches = mql.matches;
		mql.addEventListener('change', (e) => {
			matches = e.matches;
		});
	}
	return {
		get current() {
			return matches;
		}
	};
}

export const isMobile = createIsMobile();
