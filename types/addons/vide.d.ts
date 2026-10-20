import type Vide = require("@rbxts/vide");
import type Scribe from "@rbxts/scribe";

/** Bind the shared Luau adapter to your Vide installation. */
declare function ScribeVide(vide: Pick<typeof Vide, "source">): ScribeVide.Adapter;

declare namespace ScribeVide {
	type Adapter =
		/** Tracks an accessor in a source; register the disconnect with vide.cleanup. */
		<T>(this: void, accessor: Scribe.ReadableNode<T>) => LuaTuple<[Vide.Source<T>, () => void]>;
}

export = ScribeVide;
