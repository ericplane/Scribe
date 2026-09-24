import type Scribe from "@rbxts/scribe";

/** Optional server-side bridge to Roblox's built-in player list. */
declare namespace ScribeLeaderstats {
	interface DataAPI {
		readonly WaitForData: (this: void, player: Player, timeout?: number) => LuaTuple<[
			{ readonly Get: (this: void) => unknown } | undefined,
			string | undefined,
		]>;
		readonly SessionEnded: Pick<Scribe.Signal<[Player, Scribe.LifecycleReason]>, "Connect">;
	}
	type Join<Key extends string, Path> = Path extends string ? `${Key}.${Path}` : never;
	/** Static, always-present scalar paths. Containers, optional fields and Big values are excluded. */
	type Paths<T, Depth extends unknown[] = []> =
		Depth extends [unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown] ? never
		: undefined extends T ? never
		: T extends number | string | boolean ? ""
		: T extends Scribe.BigValue | Scribe.Datatype | buffer | ReadonlyArray<unknown> | ReadonlyMap<unknown, unknown> | ReadonlySet<unknown> ? never
		: T extends object ? {
			[Key in Extract<keyof T, string>]: string extends Key ? never
				: Key extends "" | `${string}.${string}` ? never
				: Paths<T[Key], [...Depth, unknown]> extends infer Path
					? Path extends "" ? Key : Join<Key, Path> : never
		}[Extract<keyof T, string>] : never;
	type Values<Data extends DataAPI> = ReturnType<NonNullable<ReturnType<Data["WaitForData"]>[0]>["Get"]>;
	type Stats<Data extends DataAPI> = { readonly [displayName: string]: Paths<Values<Data>> };
	interface Handle {
		/** Disconnect and remove only the instances created by this handle. Safe to repeat. */
		Stop(): void;
	}
	/** Dependency overrides for isolated tests. Omit in game code. */
	interface Dependencies {
		Players?: Pick<Players, "GetPlayers" | "PlayerAdded" | "PlayerRemoving">;
		NewInstance?: (this: void, className: string) => Instance;
		IsServer?: (this: void) => boolean;
		Warn?: (this: void, message: string) => void;
	}
	/** Every selected stat is public to every client, including ServerOnly/Session paths. */
	function Start<Data extends DataAPI>(data: Data, stats: Stats<NoInfer<Data>>, dependencies?: Dependencies): Handle;
}

export = ScribeLeaderstats;
