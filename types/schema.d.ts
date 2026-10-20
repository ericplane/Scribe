/** Schema declarations have no JavaScript runtime; Scribe constructs the markers in Luau. */
declare const declaration: unique symbol;
export interface Declaration<K extends string, T> {
    readonly [declaration]: readonly [K, T];
}
export type ServerOnly<T> = Declaration<"ServerOnly", T>;
export type Shared<T> = Declaration<"Shared", T>;
export type Session<T> = Declaration<"Session", T>;
export type Timed<T> = Declaration<"Timed", T>;
export type Derived<T> = Declaration<"Derived", T>;
export type Optional<T> = Declaration<"Optional", T>;
export type ArrayOf<T> = Declaration<"ArrayOf", T>;
export type DictOf<T> = Declaration<"DictOf", T>;
export type MapOf<K extends "integer" | "string", T> = Declaration<"MapOf", readonly [K, T]>;
export type SetOf<T> = Declaration<"SetOf", T>;
export type Flags<K extends string = string> = Declaration<"Flags", K>;
export type EnumValue<K extends string> = Declaration<"Enum", K>;
export type BigSchema = Declaration<"Big", BigValue>;
export type Disconnect = (this: void) => void;
/** Numeric strings are validated at runtime and limited to 256 bytes before whitespace removal. */
export type BigOperand = BigValue | number | string;

/** Immutable mantissa/exponent value. These are genuine Luau self methods. */
export interface BigValue {
    /** The normalized mantissa, including its sign. */
    readonly M: number;
    /** The base-10 exponent. */
    readonly E: number;
    /** Returns the sum as a new Big value. */
    Add(other: BigOperand): BigValue;
    /** Returns the difference as a new Big value. */
    Subtract(other: BigOperand): BigValue;
    /** Returns the product as a new Big value. */
    Multiply(other: BigOperand): BigValue;
    /** Returns the quotient as a new Big value; rejects division by zero. */
    Divide(other: BigOperand): BigValue;
    /** Returns a new Big value with the opposite sign. */
    Negate(): BigValue;
    /** Returns -1, 0 or 1 when smaller, equal or larger than the other value. */
    Compare(other: BigOperand): number;
    /** Checks whether the numeric values are equal. */
    Equals(other: BigOperand): boolean;
    /** Returns a new power; the exponent must be an integer from 0 to 2^53. */
    Pow(exponent: number): BigValue;
    /** Returns the base-10 logarithm as a plain number. */
    Log10(): number;
    /** Formats a compact label, using two decimal places by default. */
    Short(decimals?: number): string;
    /** Converts to a plain number, which can lose precision or overflow. */
    ToNumber(): number;
}

export type Datatype = Vector3 | Vector2 | Vector3int16 | Vector2int16 | CFrame | Color3 |
    BrickColor | UDim | UDim2 | Rect | NumberRange | NumberSequence | ColorSequence |
    DateTime | EnumItem | Font | PhysicalProperties;
export type AtomicValue = Datatype | buffer | BigValue;
type Widen<T> = T extends number ? number : T extends boolean ? boolean : T extends string ? string : T;
type KeyOfMap<K> = K extends "integer" ? number : string;
type OptionalField<T> = undefined extends T ? true : T extends Declaration<infer K, infer V>
    ? K extends "Optional" ? true : K extends "ServerOnly" | "Shared" | "Session" ? OptionalField<V> : false
    : false;
type Simplify<T> = { [K in keyof T]: T[K] };
type ValueRecord<T> = Simplify<{
    -readonly [K in keyof T as OptionalField<T[K]> extends true ? never : K]: ValueOf<T[K]>;
} & {
    -readonly [K in keyof T as OptionalField<T[K]> extends true ? K : never]?: ValueOf<T[K]>;
}>;
type InputRecord<T> = Simplify<{
    readonly [K in keyof T as OptionalField<T[K]> extends true ? never : K]: InputOf<T[K]>;
} & {
    readonly [K in keyof T as OptionalField<T[K]> extends true ? K : never]?: InputOf<T[K]>;
}>;

/** Plain, detached value shape; marker wrappers never appear in saved/read values. */
export type ValueOf<T> = T extends Declaration<infer K, infer V>
    ? K extends "Big" ? BigValue
    : K extends "Enum" ? V
    : K extends "Optional" ? ValueOf<V> | undefined
    : K extends "Flags" ? Extract<V, string>[]
    : K extends "ArrayOf" | "SetOf" ? ValueOf<V>[]
    : K extends "DictOf" ? { [key: string]: ValueOf<V> | undefined }
    : K extends "MapOf" ? V extends readonly [infer MK, infer MV] ? Map<KeyOfMap<MK>, ValueOf<MV>> : never
    : ValueOf<V>
    : T extends AtomicValue ? T
    : T extends ReadonlyArray<infer E> ? ValueOf<E>[]
    : T extends ReadonlyMap<infer K, infer V> ? Map<K, ValueOf<V>>
    : T extends object ? ValueRecord<T>
    : Widen<T>;

export type DeepReadonly<T> = T extends AtomicValue ? T
    : T extends ReadonlyArray<infer V> ? ReadonlyArray<DeepReadonly<V>>
    : T extends ReadonlyMap<infer K, infer V> ? ReadonlyMap<K, DeepReadonly<V>>
    : T extends object ? { readonly [K in keyof T]: DeepReadonly<T[K]> } : T;

/** Accepted writes. Big values additionally accept numbers and decimal strings. */
export type InputOf<T> = T extends Declaration<infer K, infer V>
    ? K extends "Big" ? BigOperand
    : K extends "Enum" ? V
    : K extends "Optional" ? InputOf<V> | undefined
    : K extends "Flags" ? ReadonlyArray<Extract<V, string>>
    : K extends "ArrayOf" ? ReadonlyArray<ElementInput<V>>
    : K extends "SetOf" ? ReadonlyArray<InputOf<V>>
    : K extends "DictOf" ? { readonly [key: string]: ElementInput<V> | undefined }
    : K extends "MapOf" ? V extends readonly [infer MK, infer MV] ? ReadonlyMap<KeyOfMap<MK>, ElementInput<MV>> : never
    : InputOf<V>
    : T extends Datatype | buffer ? T
    : T extends BigValue ? BigOperand
    : T extends ReadonlyArray<infer E> ? ReadonlyArray<InputOf<E>>
    : T extends ReadonlyMap<infer K, infer V> ? ReadonlyMap<K, InputOf<V>>
    : T extends object ? InputRecord<T>
    : Widen<T>;

/** Declared container elements fill omitted record fields from their defaults. */
export type ElementInput<T> = T extends Declaration<infer K, infer V>
    ? K extends "ServerOnly" | "Shared" | "Session" | "Timed" | "Derived" ? ElementInput<V>
    : K extends "Optional" ? ElementInput<V> | undefined
    : InputOf<T>
    : T extends AtomicValue ? InputOf<T>
    : T extends ReadonlyArray<infer E> ? ReadonlyArray<InputOf<E>>
    : T extends ReadonlyMap<infer K, infer V> ? ReadonlyMap<K, InputOf<V>>
    : T extends object ? string extends keyof T ? InputOf<T>
        : number extends keyof T ? InputOf<T>
        : { readonly [K in keyof T]?: ElementInput<T[K]> }
    : InputOf<T>;
type WriteInput<T, Closed extends boolean> = Closed extends true ? ElementInput<T> : InputOf<T>;

type Hidden<T> = T extends ServerOnly<unknown> ? true
    : T extends Declaration<"Shared" | "Session" | "Timed" | "Optional" | "Derived", infer V> ? Hidden<V> : false;
export type ClientSchema<T> = T extends Declaration<infer K, infer V>
    ? K extends "ServerOnly" ? never
    : K extends "MapOf" ? V extends readonly [infer MK, infer MV] ? MapOf<Extract<MK, "integer" | "string">, ClientSchema<MV>> : never
    : K extends "Big" | "Flags" | "Enum" ? T
    : Declaration<K, ClientSchema<V>>
    : T extends AtomicValue ? T
    : T extends ReadonlyArray<infer E> ? ClientSchema<E>[]
    : T extends object ? { [K in keyof T as Hidden<T[K]> extends true ? never : K]: ClientSchema<T[K]> }
    : T;
type IsShared<T> = T extends Shared<unknown> ? true
    : T extends Session<infer V> ? IsShared<V> : false;
export type SharedSchema<T> = { [K in keyof T as IsShared<T[K]> extends true ? K : never]: ClientSchema<T[K]> };

/** Adapters can depend on this small structural interface without knowing a schema. */
export interface ReadableNode<T> {
    /** Returns the current value. */
    readonly Get: (this: void) => T;
    /** Calls back now and on changes; returns a disconnect function. */
    readonly Observe: (this: void, callback: (this: void, value: T) => void) => Disconnect;
    /** Calls back on changes with new and old values; returns a disconnect function. */
    readonly Changed: (this: void, callback: (this: void, value: T, previous: T) => void) => Disconnect;
}
type Maybe<T, Missing extends boolean> = Missing extends true ? T | undefined : T;
type Read<T, Missing extends boolean> = Maybe<DeepReadonly<ValueOf<T>>, Missing>;
interface ReadOperations<T, Missing extends boolean, Closed extends boolean> extends ReadableNode<Read<T, Missing>> {
    /** Calling an accessor without arguments is its Get shorthand. */
    (this: void): Read<T, Missing>;
    /** Returns a detached, mutable copy of the current value. */
    readonly Clone: (this: void) => Maybe<ValueOf<T>, Missing>;
    /** Returns a copy of the declared default, or undefined for an undeclared field. */
    readonly Default: (this: void) => Missing extends true ? Closed extends true ? ValueOf<T> : ValueOf<T> | undefined : ValueOf<T>;
}
interface WriteOperations<T, Missing extends boolean, Closed extends boolean> {
    /** Sets the value; shorthand for Set. */
    (this: void, value: WriteInput<T, Closed>, replicate?: boolean): ValueOf<T>;
    /** Updates the value through a callback; shorthand for Update. */
    (this: void, update: (this: void, current: Read<T, Missing>) => WriteInput<T, Closed>, replicate?: boolean): ValueOf<T>;
    /** Validates and sets the value, returning the result. */
    readonly Set: (this: void, value: WriteInput<T, Closed>, replicate?: boolean) => ValueOf<T>;
    /** Passes the current value to the callback and validates its replacement. */
    readonly Update: (this: void, update: (this: void, current: Read<T, Missing>) => WriteInput<T, Closed>, replicate?: boolean) => ValueOf<T>;
}
type Unwrap<T> = T extends Declaration<"ServerOnly" | "Shared" | "Session" | "Timed" | "Derived" | "Optional", infer V> ? Unwrap<V> : Exclude<T, undefined>;
type HasKind<T, Kind extends string> = T extends Declaration<infer K, infer V>
    ? K extends Kind ? true : K extends "ServerOnly" | "Shared" | "Session" | "Timed" | "Derived" | "Optional" ? HasKind<V, Kind> : false
    : false;
type IsReadOnly<T, ReadOnly extends boolean> = ReadOnly extends true ? true : HasKind<T, "Derived">;
type Mutate<T, Root extends boolean, Missing extends boolean, ReadOnly extends boolean, Closed extends boolean> = Root extends true ? {}
    : IsReadOnly<T, ReadOnly> extends true ? {} : WriteOperations<T, Missing, Closed>;
type Bound = number | string;
type AmountOptions = boolean | import("./common").EconomyMeta;
interface NumberRead {
    /** Returns the declared minimum, or undefined when unbounded. */
    readonly Min: (this: void) => number | undefined;
    /** Returns the declared maximum, or undefined when unbounded. */
    readonly Max: (this: void) => number | undefined;
}
interface NumberWrite {
    /** Adds an amount and returns the updated value. */
    readonly Increment: (this: void, amount: number, options?: AmountOptions) => number;
    /** Subtracts an amount and returns the updated value. */
    readonly Decrement: (this: void, amount: number, options?: AmountOptions) => number;
}
interface BigRead {
    /** Returns the declared minimum, or undefined when unbounded. */
    readonly Min: (this: void) => Bound | undefined;
    /** Returns the declared maximum, or undefined when unbounded. */
    readonly Max: (this: void) => Bound | undefined;
}
interface BigWrite {
    /** Adds an amount and returns the updated Big value. */
    readonly Increment: (this: void, amount: BigOperand, options?: AmountOptions) => BigValue;
    /** Subtracts an amount and returns the updated Big value. */
    readonly Decrement: (this: void, amount: BigOperand, options?: AmountOptions) => BigValue;
    /** Multiplies the field and returns the updated Big value. */
    readonly Multiply: (this: void, amount: BigOperand, replicate?: boolean) => BigValue;
    /** Divides the field and returns the updated Big value; rejects zero. */
    readonly Divide: (this: void, amount: BigOperand, replicate?: boolean) => BigValue;
}
type WritableOnly<T, ReadOnly extends boolean, Methods> = IsReadOnly<T, ReadOnly> extends true ? {} : Methods;
type ScalarMethods<T, ReadOnly extends boolean> = Unwrap<T> extends number ? NumberRead & WritableOnly<T, ReadOnly, NumberWrite>
    : Unwrap<T> extends boolean ? WritableOnly<T, ReadOnly, {
        /** Flips the boolean and returns its new value. */
        readonly Toggle: (this: void, replicate?: boolean) => boolean
    }>
    : Unwrap<T> extends BigSchema | BigValue ? BigRead & WritableOnly<T, ReadOnly, BigWrite> : {};

type ChildEvents<K, V> = {
    /** Observes child changes by key; returns a disconnect function. */
    readonly OnChildChanged: (this: void, callback: (this: void, key: K, value: DeepReadonly<V> | undefined, previous: DeepReadonly<V> | undefined) => void) => Disconnect;
};
type CollectionRead<K, E, ReadOnly extends boolean, Closed extends boolean, Client extends boolean> = ChildEvents<K, ValueOf<E>> & {
    /** Exact Luau key. Array positions start at 1; map keys are never shifted. */
    readonly Child: (this: void, key: K) => Accessor<E, false, true, ReadOnly, Closed, Client>;
    /** Returns the number of entries. */
    readonly Count: (this: void) => number;
};
type ArrayMethods<T, E, ReadOnly extends boolean, Closed extends boolean, Client extends boolean> = CollectionRead<number, E, ReadOnly, Closed, Client> & {
    readonly [index: number]: Accessor<E, false, true, ReadOnly, Closed, Client>;
    /** Returns the first 1-based position, or undefined when absent. */
    readonly Find: (this: void, value: InputOf<E>) => number | undefined;
    /** Checks whether the collection contains the value. */
    readonly Has: (this: void, value: InputOf<E>) => boolean;
    /** Observes insertions with the value and position; returns a disconnect function. */
    readonly OnInsert: (this: void, callback: (this: void, value: DeepReadonly<ValueOf<E>>, index: number) => void) => Disconnect;
    /** Observes removals with the value and former position; returns a disconnect function. */
    readonly OnRemove: (this: void, callback: (this: void, value: DeepReadonly<ValueOf<E>>, index: number) => void) => Disconnect;
} & WritableOnly<T, ReadOnly, {
    /** Inserts at a 1-based position, or appends when omitted. */
    readonly Insert: (this: void, value: WriteInput<E, Closed>, position?: number, replicate?: boolean) => void;
    /** Removes and returns an entry, defaulting to the last position. */
    readonly Remove: (this: void, position?: number, replicate?: boolean) => ValueOf<E> | undefined;
    /** Removes the first match and returns its value and position, or two undefined values. */
    readonly RemoveValue: (this: void, value: InputOf<E>, replicate?: boolean) => LuaTuple<[ValueOf<E> | undefined, number | undefined]>;
    /** Removes every entry. */
    readonly Clear: (this: void, replicate?: boolean) => void;
}>;
type DictMethods<T, K extends string | number, E, ReadOnly extends boolean, Closed extends boolean, Client extends boolean> = CollectionRead<K, E, ReadOnly, Closed, Client> & {
    readonly [P in K]: Accessor<E, false, true, ReadOnly, Closed, Client>;
} & {
    /** Observes new keys and their values; returns a disconnect function. */
    readonly OnKeyAdded: (this: void, callback: (this: void, key: K, value: DeepReadonly<ValueOf<E>>) => void) => Disconnect;
    /** Observes removed keys and their values; returns a disconnect function. */
    readonly OnKeyRemoved: (this: void, callback: (this: void, key: K, value: DeepReadonly<ValueOf<E>>) => void) => Disconnect;
} & WritableOnly<T, ReadOnly, {
    /** Removes the key and returns its previous value, or undefined when absent. */
    readonly Remove: (this: void, key: K, replicate?: boolean) => ValueOf<E> | undefined;
    /** Removes every entry. */
    readonly Clear: (this: void, replicate?: boolean) => void;
}>;
type SetMethods<T, E, ReadOnly extends boolean> = {
    /** Checks whether the collection contains the value. */
    readonly Has: (this: void, value: InputOf<E>) => boolean;
    /** Returns the first 1-based position, or undefined when absent. */
    readonly Find: (this: void, value: InputOf<E>) => number | undefined;
    /** Returns the number of entries. */
    readonly Count: (this: void) => number;
} & WritableOnly<T, ReadOnly, {
    /** Adds a set member; returns false if already present. */
    readonly Add: (this: void, value: InputOf<E>, replicate?: boolean) => boolean;
    /** Removes a set member; returns false if absent. */
    readonly Remove: (this: void, value: InputOf<E>, replicate?: boolean) => boolean;
    /** Removes every entry. */
    readonly Clear: (this: void, replicate?: boolean) => void;
}>;
type FlagsMethods<T, K extends string, ReadOnly extends boolean> = {
    /** Checks whether the flag is enabled. */
    readonly Has: (this: void, member: K) => boolean;
} & WritableOnly<T, ReadOnly, {
    /** Enables the named flag. */
    readonly Enable: (this: void, member: K, replicate?: boolean) => void;
    /** Disables the named flag. */
    readonly Disable: (this: void, member: K, replicate?: boolean) => void;
    /** Flips the named flag and returns whether it is enabled. */
    readonly Toggle: (this: void, member: K, replicate?: boolean) => boolean;
    /** Disables every flag. */
    readonly Clear: (this: void, replicate?: boolean) => void;
}>;
type ReservedMethod = "Get" | "Set" | "Update" | "Clone" | "Default" | "Changed" | "Observe" | "Child" |
    "OnChildChanged" | "Count" | "Clear" | "Insert" | "Remove" | "RemoveValue" | "Find" | "Has" |
    "OnInsert" | "OnRemove" | "OnKeyAdded" | "OnKeyRemoved" | "Increment" | "Decrement" | "Min" | "Max" |
    "Toggle" | "Enable" | "Disable" | "Add" | "Multiply" | "Divide" | "SetTimed" | "ExtendTimed" | "Active";
type ChildMissing<T, Missing extends boolean> = Missing extends true ? true : OptionalField<T>;
type RecordMethods<T, S, Missing extends boolean, ReadOnly extends boolean, Closed extends boolean, Client extends boolean> = {
    readonly [K in keyof S as K extends ReservedMethod ? never : K]-?: Accessor<S[K], false, ChildMissing<T, Missing>, IsReadOnly<T, ReadOnly>, Closed, Client>;
} & {
    /** Accesses a child by name, including keys that match methods. */
    readonly Child: <K extends Extract<keyof S, string | number>>(this: void, key: K) => Accessor<S[K], false, ChildMissing<T, Missing>, IsReadOnly<T, ReadOnly>, Closed, Client>;
} & ChildEvents<Extract<keyof S, string | number>, ValueOf<S[keyof S]>>;

type ShapeMethods<T, S, Missing extends boolean, ReadOnly extends boolean, Closed extends boolean, Client extends boolean> = S extends ArrayOf<infer E>
    ? ArrayMethods<T, E, ReadOnly, true, Client>
    : S extends DictOf<infer E> ? DictMethods<T, string, E, ReadOnly, true, Client>
    : S extends MapOf<infer K, infer E> ? DictMethods<T, KeyOfMap<K>, E, ReadOnly, true, Client>
    : S extends SetOf<infer E> ? SetMethods<T, E, ReadOnly>
    : S extends Flags<infer K> ? FlagsMethods<T, K, ReadOnly>
    : S extends Declaration<string, unknown> | AtomicValue ? {}
    : S extends ReadonlyArray<infer E> ? ArrayMethods<T, E, ReadOnly, false, Client>
    : S extends object ? string extends keyof S ? DictMethods<T, string, S[string & keyof S], ReadOnly, false, Client>
        : number extends keyof S ? ArrayMethods<T, S[number & keyof S], ReadOnly, false, Client>
        : RecordMethods<T, S, Missing, ReadOnly, Closed, Client>
    : {};
// Only the server changes timer deadlines.
type TimedMethods<T, ReadOnly extends boolean, Client extends boolean> = HasKind<T, "Timed"> extends true ? {
    /** Timer state and seconds left. Clients read replicated deadlines; inactive returns false, undefined. */
    readonly Active: (this: void) => LuaTuple<[boolean, number | undefined]>;
} & WritableOnly<T, Client extends true ? true : ReadOnly, {
    /** Sets the value until its timer expires, then restores the default; server only. */
    readonly SetTimed: (this: void, value: InputOf<T>, seconds: number, replicate?: boolean) => void;
    /** Adds seconds to the timer, starting from now if inactive; server only. */
    readonly ExtendTimed: (this: void, seconds: number, replicate?: boolean) => void;
}> : {};

/** Proxy objects, not native Array/Map instances. Client omits SetTimed/ExtendTimed. */
export type Accessor<T, Root extends boolean = false, Missing extends boolean = false, ReadOnly extends boolean = false, Closed extends boolean = false, Client extends boolean = false> =
    ReadOperations<T, Missing, Closed> & Mutate<T, Root, Missing, ReadOnly, Closed> & ScalarMethods<T, ReadOnly> &
    ShapeMethods<T, Unwrap<T>, Missing, ReadOnly, Closed, Client> & TimedMethods<T, ReadOnly, Client>;
export type PlayerData<T> = Accessor<T, true>;
export type ReadonlyAccessor<T, Root extends boolean = false> = Accessor<T, Root, false, true>;

type Join<K extends string, P> = P extends string ? `${K}.${P}` : never;
/** Static numeric leaf paths only. Dynamic keys require a runtime-validated path. */
export type NumericPaths<T, IncludeBig extends boolean = false, Depth extends unknown[] = []> =
    Depth extends [unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown] ? never
    : Unwrap<T> extends number ? ""
    : Unwrap<T> extends BigSchema | BigValue ? IncludeBig extends true ? "" : never
    : Unwrap<T> extends AtomicValue | Declaration<string, unknown> | ReadonlyArray<unknown> ? never
    : Unwrap<T> extends object ? {
        [K in Extract<keyof Unwrap<T>, string>]: string extends K ? never :
            NumericPaths<Unwrap<T>[K], IncludeBig, [...Depth, unknown]> extends infer P
                ? P extends "" ? K : Join<K, P> : never
    }[Extract<keyof Unwrap<T>, string>] : never;
