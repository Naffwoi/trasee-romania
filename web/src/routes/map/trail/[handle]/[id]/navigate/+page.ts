import { trails_show } from "#lib/stores/trail_store.ts";
import { APIError } from "#lib/util/api_util.ts";
import { remoteContentError } from "#lib/util/remote_content_error.ts";
import { error, type Load } from "@sveltejs/kit";

export const ssr = false;

export const load: Load = async ({ params, url, fetch }) => {
    try {
        const trail = await trails_show(
            params.id!,
            params.handle,
            url.searchParams.get("share") ?? undefined,
            false,
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
