// SSG Racing 8x8 matrix - THE SAME FLAG AS PADDOCK, FOR AS LONG AS IRACING SHOWS IT
// Peter 2026-11-02: green too short, a blue on Paddock but not on the lights, "everything needs to be coordinated".
// So this reads iRacing's own flag bits (the numbers Paddock reads), in Paddock's order (dash\www\v2\ui.js, tests\df8-flags-test.ps1
// proves the two tables match). No timers cut a flag short: the box is lit until iRacing takes the flag away.
// SimHub's Flag_Blue missed a real blue, and SimHub's own iRacing profiles read the raw bits too. Flag_* is only the fallback.
// SimHub's free edition draws 10 frames a second, so nothing here changes faster than every 100 ms.
// ---- settings you can change (ms) ----
const STROBE_MS = { yellow: 30000, red: 5000, white: 5000, green: 5000 };   // flashing this long, then steady until the flag ends
const SHOW_SPOTTER = true;      // left/right column red when a car is beside you
const SHOW_PIT_LIMITER = true;  // blue P while the pit limiter is on
// --------------------------------------
// FLAG TABLE START - the same text is in dash\www\v2\ui.js
const FLAG_MIN_MS = 3000;       // a 1 s blue is real: every flag shows at least this long
const FLAG_ORDER = [['black', 0x30000], ['orange', 0x100000], ['warning', 0x80000], ['checkered', 0x1], ['red', 0x10], ['yellow', 0xC148], ['blue', 0x20], ['white', 0x2], ['green', 0x4]];
// FLAG TABLE END
const BIT = { checkered: 0x1, white: 0x2, green: 0x4, yellow: 0x8, red: 0x10, blue: 0x20, debris: 0x40, yellowWaving: 0x100, caution: 0x4000, cautionWaving: 0x8000, black: 0x10000, disqualify: 0x20000, furled: 0x80000, repair: 0x100000 };
const OFF = '#FF000000', WHITE = '#FFFFFFFF', YELLOW = '#FFFFC800', BLUE = '#FF0050FF', ORANGE = '#FFFF8C00', GREEN = '#FF00FF00', RED = '#FFFF0000';
const DISC = [10,11,12,13,17,18,19,20,21,22,25,26,27,28,29,30,33,34,35,36,37,38,41,42,43,44,45,46,50,51,52,53];
const out = new Array(64).fill(OFF);
const now = Date.now();
const set = (idx, c) => { for (const i of idx) out[i] = c; };
const row = (r, c) => { for (let x = 0; x < 8; x++) out[r * 8 + x] = c; };
const col = (x, c) => { for (let r = 0; r < 8; r++) out[r * 8 + x] = c; };
const fill = (c) => out.fill(c);
const frame = (c) => { row(0, c); row(7, c); col(0, c); col(7, c); };
const step = (ms) => Math.floor(now / ms);

const readBits = () => {
	let v = $prop('DataCorePlugin.GameRawData.Telemetry.SessionFlags');
	if (v === null || v === undefined) v = $prop('GameRawData.Telemetry.SessionFlags');
	if (typeof v === 'number') return v;
	if (v !== null && v !== undefined) {              // iRacing's flag type can arrive as an object: its text is a number or names ("green, blue")
		const s = String(v);
		if (/^-?\d+$/.test(s)) return Number(s);
		if (/^[A-Za-z]+(, *[A-Za-z]+)*$/.test(s)) {
			let b = 0;
			for (const n of s.split(',')) b |= BIT[n.trim()] || 0;
			return b;
		}
	}
	const on = (n) => $prop(n) == 1;                  // raw value not readable: SimHub's own signals, so the box still works
	const d = (n) => on('DataCorePlugin.GameRawData.Telemetry.SessionFlagsDetails.' + n) || on('GameRawData.Telemetry.SessionFlagsDetails.' + n);
	return (on('Flag_Checkered') ? BIT.checkered : 0) | (on('Flag_White') ? BIT.white : 0) | (on('Flag_Green') || d('Isgreen') ? BIT.green : 0)
		| (on('Flag_Yellow') || d('Isyellow') ? BIT.yellow : 0) | (d('Isred') ? BIT.red : 0) | (on('Flag_Blue') || d('IsBlue') ? BIT.blue : 0) | (d('Isdebris') ? BIT.debris : 0)
		| (d('IsCaution') ? BIT.caution : 0) | (d('IsCautionwaving') ? BIT.cautionWaving : 0) | (on('Flag_Black') ? BIT.black : 0) | (on('Flag_Orange') || d('Isrepair') ? BIT.repair : 0);
};

const st = globalThis.__ssgFlags || (globalThis.__ssgFlags = { was: {}, until: {}, since: {}, cur: '' });
const bits = readBits();
let flag = '';
for (const [name, mask] of FLAG_ORDER) {               // every flag is read every frame, so a short one keeps its 3 s under a higher one
	const on = (bits & mask) !== 0;
	if (on && !st.was[name]) { st.until[name] = now + FLAG_MIN_MS; st.since[name] = now; }
	st.was[name] = on;
	if (!flag && (on || now < (st.until[name] || 0))) flag = name;
}
st.cur = flag;
const strobing = now - (st.since[flag] || 0) < (STROBE_MS[flag] || 0);

if (flag == 'checkered') {                             // moving black and white board
	const t = step(200) % 2;
	for (let i = 0; i < 64; i++) out[i] = ((Math.floor(i / 16) + Math.floor((i % 8) / 2) + t) % 2) ? WHITE : OFF;
} else if (flag == 'black') {                          // white frame swapping with a red cross
	if (step(200) % 2 == 0) frame(WHITE);
	else for (let i = 0; i < 8; i++) { out[i * 8 + i] = RED; out[i * 8 + 7 - i] = RED; }
} else if (flag == 'warning') {                        // furled black: a steady white frame
	frame(WHITE);
} else if (flag == 'orange') {                         // meatball: full orange box swapping with an orange disc
	if (step(200) % 2 == 0) fill(ORANGE); else set(DISC, ORANGE);
} else if (flag == 'red') {
	if (!strobing || step(200) % 2 == 0) fill(RED);
} else if (flag == 'yellow') {
	if (!strobing || step(100) % 2 == 0) fill(YELLOW);
} else if (flag == 'blue') {                           // full blue with a dark bar racing across it
	fill(BLUE);
	const x = step(100) % 8;
	col(x, OFF); col((x + 1) % 8, OFF);
} else if (flag == 'white') {                          // a whole lap of solid white is too much at night: flash, then a frame
	if (strobing) { if (step(200) % 2 == 0) fill(WHITE); } else frame(WHITE);
} else if (flag == 'green') {
	if (!strobing || step(200) % 2 == 0) fill(GREEN);
} else if (SHOW_PIT_LIMITER && $prop('PitLimiterOn') == 1) {
	set([1,2,3,4,5,9,10,13,14,17,18,21,22,25,26,27,28,29,33,34,41,42,49,50], BLUE);
}

if (SHOW_SPOTTER) {
	if ($prop('SpotterCarLeft') == 1) col(0, RED);
	if ($prop('SpotterCarRight') == 1) col(7, RED);
}
return out;
