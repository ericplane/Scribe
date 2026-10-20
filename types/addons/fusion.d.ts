import type Scribe from "@rbxts/scribe";

/** Fusion 0.2: call the returned disconnect when the UI is destroyed. */
declare function ScribeFusion(fusion: ScribeFusion.LegacyFramework): ScribeFusion.Adapter;
/** Fusion 0.3: the disconnect is also registered in the supplied cleanup scope. */
declare function ScribeFusion<Scope extends unknown[], Framework extends ScribeFusion.ScopedFramework<Scope>>(
	fusion: Framework,
	scope: Scope,
): ScribeFusion.ScopedAdapter<ReturnType<Framework["Value"]>>;

declare namespace ScribeFusion {
	type Adapter =
		/** Tracks an accessor in a Fusion value; disconnect when finished. */
		<T>(this: void, accessor: Scribe.ReadableNode<T>) => LuaTuple<[LegacyValue<T>, () => void]>;
	type ScopedAdapter<Value extends ScopedValue<unknown> = ScopedValue<unknown>> =
		/** Tracks an accessor in a Fusion value and registers scope cleanup. */
		<T>(
		this: void,
		accessor: Scribe.ReadableNode<T>,
	) => LuaTuple<[Omit<Value, "set" | "_EXTREMELY_DANGEROUS_usedAsValue"> & ScopedValue<T>, () => void]>;
	/** Structurally compatible with @rbxts/fusion 0.2's Value<T>. */
	interface LegacyValue<T> {
		readonly type: "State";
		readonly kind: "Value";
		/** Returns the current Fusion value. */
		get(asDependency?: boolean): T;
		/** Updates the Fusion value without writing to Scribe. */
		set(value: T, force?: boolean): void;
	}
	interface LegacyFramework {
		/** Creates a Fusion value with the initial value. */
		readonly Value: <T>(this: void, initialValue: T) => LegacyValue<T>;
	}
	/** Public surface of a Fusion 0.3 Value. Read it through your framework's peek/use. */
	interface ScopedValue<T> {
		readonly type: "State";
		readonly kind: "Value";
		/** @internal Present for compatibility with Fusion's StateObject<T> inference. Do not read directly. */
		readonly _EXTREMELY_DANGEROUS_usedAsValue: T;
		/** Updates the Fusion value without writing to Scribe. */
		set(value: T): void;
	}
	/** The 0.3 package is supplied by the caller; no separate framework is bundled. */
	interface ScopedFramework<Scope> {
		/** Creates a Fusion value owned by the supplied scope. */
		readonly Value: <T>(this: void, scope: Scope, initialValue: T) => ScopedValue<T>;
	}
}

export = ScribeFusion;
