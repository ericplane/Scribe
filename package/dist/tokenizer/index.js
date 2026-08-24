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
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : new P(function (resolve) { resolve(result.value); }).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
var __generator = (this && this.__generator) || function (thisArg, body) {
    var _ = { label: 0, sent: function() { if (t[0] & 1) throw t[1]; return t[1]; }, trys: [], ops: [] }, f, y, t, g;
    return g = { next: verb(0), "throw": verb(1), "return": verb(2) }, typeof Symbol === "function" && (g[Symbol.iterator] = function() { return this; }), g;
    function verb(n) { return function (v) { return step([n, v]); }; }
    function step(op) {
        if (f) throw new TypeError("Generator is already executing.");
        while (_) try {
            if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
            if (y = 0, t) op = [op[0] & 2, t.value];
            switch (op[0]) {
                case 0: case 1: t = op; break;
                case 4: _.label++; return { value: op[1], done: false };
                case 5: _.label++; y = op[1]; op = [0]; continue;
                case 7: op = _.ops.pop(); _.trys.pop(); continue;
                default:
                    if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
                    if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
                    if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
                    if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
                    if (t[2]) _.ops.pop();
                    _.trys.pop(); continue;
            }
            op = body.call(thisArg, _);
        } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
        if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
    }
};
Object.defineProperty(exports, "__esModule", { value: true });
/**
 * Tokenizer.encode() is a port of `EncodeAsIds` from the SentencePiece library
 * (https://github.com/google/sentencepiece). Encode uses the Viterbi algorithm
 * to find the most likely sequence of tokens that comprise the input. For more
 * details, refer to https://arxiv.org/pdf/1804.10959.pdf.
 */
var tf = require("@tensorflow/tfjs-core");
var util_1 = require("../util");
var trie_1 = require("./trie");
var separator = '\u2581'; // This is the unicode character 'lower one eighth block'.
function processInput(str) {
    var normalized = str.normalize('NFKC');
    return normalized.length > 0 ?
        separator + normalized.replace(/ /g, separator) :
        normalized;
}
// The first tokens are reserved for unk, control symbols, and user-defined
// symbols.
var RESERVED_SYMBOLS_COUNT = 6;
var Tokenizer = /** @class */ (function () {
    function Tokenizer(vocabulary, reservedSymbolsCount) {
        if (reservedSymbolsCount === void 0) { reservedSymbolsCount = RESERVED_SYMBOLS_COUNT; }
        this.vocabulary = vocabulary;
        this.reservedSymbolsCount = reservedSymbolsCount;
        this.trie = new trie_1.Trie();
        for (var i = this.reservedSymbolsCount; i < this.vocabulary.length; i++) {
            this.trie.insert(this.vocabulary[i][0], this.vocabulary[i][1], i);
        }
    }
    Tokenizer.prototype.encode = function (input) {
        var nodes = [];
        var words = [];
        var best = [];
        input = processInput(input);
        var symbols = util_1.stringToChars(input);
        for (var i = 0; i <= symbols.length; i++) {
            nodes.push({});
            words.push(0);
            best.push(0);
        }
        // Construct the lattice.
        for (var i = 0; i < symbols.length; i++) {
            var matches = this.trie.commonPrefixSearch(symbols.slice(i));
            for (var j = 0; j < matches.length; j++) {
                var piece = matches[j];
                var obj = { key: piece[0], score: piece[1], index: piece[2] };
                var endPos = piece[0].length;
                if (nodes[i + endPos][i] == null) {
                    nodes[i + endPos][i] = [];
                }
                nodes[i + endPos][i].push(obj);
            }
        }
        for (var endPos = 0; endPos <= symbols.length; endPos++) {
            for (var startPos in nodes[endPos]) {
                var arr = nodes[endPos][startPos];
                for (var j = 0; j < arr.length; j++) {
                    var word = arr[j];
                    var score = word.score + best[endPos - word.key.length];
                    if (best[endPos] === 0 || score >= best[endPos]) {
                        best[endPos] = score;
                        words[endPos] = arr[j].index;
                    }
                }
            }
        }
        var results = [];
        // Backward pass.
        var iter = words.length - 1;
        while (iter > 0) {
            results.push(words[iter]);
            iter -= this.vocabulary[words[iter]][0].length;
        }
        // Merge consecutive unks.
        var merged = [];
        var isPreviousUnk = false;
        for (var i = 0; i < results.length; i++) {
            var id = results[i];
            if (!(isPreviousUnk && id === 0)) {
                merged.push(id);
            }
            isPreviousUnk = id === 0;
        }
        return merged.reverse();
    };
    return Tokenizer;
}());
exports.Tokenizer = Tokenizer;
/**
 * Load the Tokenizer for use independently from the UniversalSentenceEncoder.
 *
 * @param pathToVocabulary (optional) Provide a path to the vocabulary file.
 */
function loadTokenizer(pathToVocabulary) {
    return __awaiter(this, void 0, void 0, function () {
        var vocabulary, tokenizer;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0: return [4 /*yield*/, loadVocabulary(pathToVocabulary)];
                case 1:
                    vocabulary = _a.sent();
                    tokenizer = new Tokenizer(vocabulary);
                    return [2 /*return*/, tokenizer];
            }
        });
    });
}
exports.loadTokenizer = loadTokenizer;
/**
 * Load a vocabulary for the Tokenizer.
 *
 * @param pathToVocabulary Defaults to the path to the 8k vocabulary used by the
 * UniversalSentenceEncoder.
 */
function loadVocabulary(pathToVocabulary) {
    return __awaiter(this, void 0, void 0, function () {
        var vocabulary;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0: return [4 /*yield*/, tf.util.fetch(pathToVocabulary)];
                case 1:
                    vocabulary = _a.sent();
                    return [2 /*return*/, vocabulary.json()];
            }
        });
    });
}
exports.loadVocabulary = loadVocabulary;
//# sourceMappingURL=index.js.map