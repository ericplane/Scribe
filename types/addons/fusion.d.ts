import type Scribe from "@rbxts/scribe";

/** Fusion 0.2: call the returned disconnect when the UI is destroyed. */
declare function ScribeFusion(fusion: ScribeFusion.LegacyFramework): ScribeFusion.Adapter;
/** Fusion 0.3: the disconnect is also registered in the supplied cleanup scope. */
declare function ScribeFusion<Scope extends unknown[], Framework extends ScribeFusion.ScopedFramework<Scope>>(
	fusion: Framework,
	scope: Scope,
): ScribeFusion.ScopedAdapter<ReturnType<Framework["Value"]>>;

declare namespace ScribeFusion {
	type Adapter = <T>(this: void, accessor: Scribe.ReadableNode<T>) => LuaTuple<[LegacyValue<T>, () => void]>;
	type ScopedAdapter<Value extends ScopedValue<unknown> = ScopedValue<unknown>> = <T>(
		this: void,
		accessor: Scribe.ReadableNode<T>,
	) => LuaTuple<[Omit<Value, "set" | "_EXTREMELY_DANGEROUS_usedAsValue"> & ScopedValue<T>, () => void]>;
	/** Structurally compatible with @rbxts/fusion 0.2's Value<T>. */
	interface LegacyValue<T> {
		readonly type: "State";
		readonly kind: "Value";
		get(asDependency?: boolean): T;
		set(value: T, force?: boolean): void;
	}
	interface LegacyFramework {
		readonly Value: <T>(this: void, initialValue: T) => LegacyValue<T>;
	}
	/** Public surface of a Fusion 0.3 Value. Read it through your framework's peek/use. */
	interface ScopedValue<T> {
		readonly type: "State";
		readonly kind: "Value";
		/** @internal Present for compatibility with Fusion's StateObject<T> inference. Do not read directly. */
		readonly _EXTREMELY_DANGEROUS_usedAsValue: T;
		set(value: T): void;
	}
	/** The 0.3 package is supplied by the caller; no separate framework is bundled. */
	interface ScopedFramework<Scope> {
		readonly Value: <T>(this: void, scope: Scope, initialValue: T) => ScopedValue<T>;
	}
}

export = ScribeFusion;
