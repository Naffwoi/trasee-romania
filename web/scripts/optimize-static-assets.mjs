import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import wawoff2 from "wawoff2";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WEB_ROOT = path.resolve(__dirname, "..");
const FONT_DIR = path.join(WEB_ROOT, "static/fonts/IBMPlexSans");
const OFM_STYLE_PATH = path.join(WEB_ROOT, "static/styles/ofm.json");

const ACTIVE_FACES = [
	"IBMPlexSans-Regular",
	"IBMPlexSans-Italic",
	"IBMPlexSans-Medium",
	"IBMPlexSans-SemiBold",
	"IBMPlexSans-Bold",
];

async function buildWoff2Fonts() {
	for (const base of ACTIVE_FACES) {
		const ttfPath = path.join(FONT_DIR, `${base}.ttf`);
		const woff2Path = path.join(FONT_DIR, `${base}.woff2`);
		const ttfBytes = await fs.readFile(ttfPath);
		const compressed = await wawoff2.compress(ttfBytes);
		await fs.writeFile(woff2Path, Buffer.from(compressed));
	}
}

async function minifyOfmStyle() {
	const raw = await fs.readFile(OFM_STYLE_PATH, "utf8");
	const parsed = JSON.parse(raw);
	delete parsed.metadata;
	for (const layer of parsed.layers ?? []) {
		delete layer.metadata;
		if (layer.layout && typeof layer.layout === "object") {
			if (layer.layout.visibility === "visible") {
				delete layer.layout.visibility;
			}
			if (Object.keys(layer.layout).length === 0) {
				delete layer.layout;
			}
		}
		if (layer.paint && typeof layer.paint === "object" && Object.keys(layer.paint).length === 0) {
			delete layer.paint;
		}
	}
	const minified = JSON.stringify(parsed);
	await fs.writeFile(OFM_STYLE_PATH, minified + "\n", "utf8");
}

await buildWoff2Fonts();
await minifyOfmStyle();
