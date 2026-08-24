"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
var test_util_1 = require("./test_util");
var tokenizer_1 = require("./tokenizer");
describe('Universal Sentence Encoder tokenizer', function () {
    var tokenizer;
    beforeAll(function () {
        tokenizer = new tokenizer_1.Tokenizer(test_util_1.stubbedTokenizerVocab);
    });
    it('Trie creates a child for each unique prefix', function () {
        var childKeys = Object.keys(tokenizer.trie.root.children);
        expect(childKeys).toEqual(['▁', 'a', '.', 'I', 'l', 'i', 'k', 'e', 't']);
    });
    it('Trie commonPrefixSearch basic usage', function () {
        var commonPrefixes = tokenizer.trie.commonPrefixSearch(['l', 'i', 'k', 'e'])
            .map(function (d) { return d[0].join(''); });
        expect(commonPrefixes).toEqual(['l', 'like']);
    });
});
//# sourceMappingURL=trie_test.js.map