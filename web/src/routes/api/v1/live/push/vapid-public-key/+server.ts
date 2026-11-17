import { getVapidPublicKey } from "#lib/server/live/vapid_push.ts";
import { json } from "@sveltejs/kit";

export async function GET() {
	const publicKey = getVapidPublicKey();
	return json({ publicKey });
}
