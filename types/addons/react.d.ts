import type React = require("@rbxts/react");
import type Scribe from "@rbxts/scribe";

/** Bind the shared Luau adapter to the React installation used by your game. */
declare function ScribeReact(react: Pick<typeof React, "useState" | "useEffect" | "useBinding">): ScribeReact.Adapter;

declare namespace ScribeReact {
	interface Adapter {
		/** Use inside a component. Changes re-render the component. */
		readonly useScribe: <T>(this: void, accessor: Scribe.ReadableNode<T>) => T;
		/** Use inside a component. Changes update the binding without a re-render. */
		readonly useScribeBinding: <T>(this: void, accessor: Scribe.ReadableNode<T>) => React.Binding<T>;
	}
}

export = ScribeReact;
