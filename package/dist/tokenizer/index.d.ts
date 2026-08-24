/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
import { Trie } from './trie';
export declare type Vocabulary = Array<[string, number]>;
export declare class Tokenizer {
    private vocabulary;
    private reservedSymbolsCount;
    trie: Trie;
    constructor(vocabulary: Vocabulary, reservedSymbolsCount?: number);
    encode(input: string): number[];
}
/**
 * Load the Tokenizer for use independently from the UniversalSentenceEncoder.
 *
 * @param pathToVocabulary (optional) Provide a path to the vocabulary file.
 */
export declare function loadTokenizer(pathToVocabulary?: string): Promise<Tokenizer>;
/**
 * Load a vocabulary for the Tokenizer.
 *
 * @param pathToVocabulary Defaults to the path to the 8k vocabulary used by the
 * UniversalSentenceEncoder.
 */
export declare function loadVocabulary(pathToVocabulary: string): Promise<any>;
