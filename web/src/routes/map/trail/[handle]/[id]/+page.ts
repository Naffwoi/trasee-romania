import { trails_show } from "#lib/stores/trail_store.ts";
import { remoteContentError } from "#lib/util/remote_content_error.ts";
import { APIError } from "#lib/util/api_util.ts";
import { error, type Load } from "@sveltejs/kit";

export const load: Load = async ({ params, url, fetch }) => {
    const isBrowser = typeof window !== "undefined";
    try {
        const trail = await trails_show(
            params.id!,
            params.handle,
            url.searchParams.get("share") ?? undefined,
            isBrowser,
            fetch,
        );
        return { trail };
    } catch (e) {
        if (e instanceof APIError) {
            const { message, ...properties } = remoteContentError(e);
            error(e.status, message, properties);
        }
        throw e;
    }
};
