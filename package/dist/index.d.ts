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
import * as tfconv from '@tensorflow/tfjs-converter';
import * as tf from '@tensorflow/tfjs-core';
import { loadTokenizer, Tokenizer } from './tokenizer';
import { loadQnA } from './use_qna';
export { version } from './version';
interface LoadConfig {
    modelUrl?: string;
    vocabUrl?: string;
}
export declare function load(config?: LoadConfig): Promise<UniversalSentenceEncoder>;
export declare class UniversalSentenceEncoder {
    private model;
    private tokenizer;
    loadModel(modelUrl?: string): Promise<tfconv.GraphModel>;
    load(config?: LoadConfig): Promise<void>;
    /**
     *
     * Returns a 2D Tensor of shape [input.length, 512] that contains the
     * Universal Sentence Encoder embeddings for each input.
     *
     * @param inputs A string or an array of strings to embed.
     */
    embed(inputs: string[] | string): Promise<tf.Tensor2D>;
}
export { Tokenizer };
export { loadTokenizer };
export { loadQnA };
