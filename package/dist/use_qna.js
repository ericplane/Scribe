"use strict";
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the 'License');
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an 'AS IS' BASIS,
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
var tfconv = require("@tensorflow/tfjs-converter");
var tf = require("@tensorflow/tfjs-core");
var tokenizer_1 = require("./tokenizer");
var version_1 = require("./version");
exports.version = version_1.version;
var BASE_PATH = 'https://tfhub.dev/google/tfjs-model/universal-sentence-encoder-qa-ondevice/1';
// Index in the vocab file that needs to be skipped.
var SKIP_VALUES = [0, 1, 2];
// Offset value for skipped vocab index.
var OFFSET = 3;
// Input tensor size limit.
var INPUT_LIMIT = 192;
// Model node name for query.
var QUERY_NODE_NAME = 'input_inp_text';
// Model node name for query.
var RESPONSE_CONTEXT_NODE_NAME = 'input_res_context';
// Model node name for response.
var RESPONSE_NODE_NAME = 'input_res_text';
// Model node name for response result.
var RESPONSE_RESULT_NODE_NAME = 'Final/EncodeResult/mul';
// Model node name for query result.
var QUERY_RESULT_NODE_NAME = 'Final/EncodeQuery/mul';
// Reserved symbol count for tokenizer.
var RESERVED_SYMBOLS_COUNT = 3;
// Value for token padding
var TOKEN_PADDING = 2;
// Start value for each token
var TOKEN_START_VALUE = 1;
function loadQnA() {
    return __awaiter(this, void 0, void 0, function () {
        var use;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0:
                    use = new UniversalSentenceEncoderQnA();
                    return [4 /*yield*/, use.load()];
                case 1:
                    _a.sent();
                    return [2 /*return*/, use];
            }
        });
    });
}
exports.loadQnA = loadQnA;
var UniversalSentenceEncoderQnA = /** @class */ (function () {
    function UniversalSentenceEncoderQnA() {
    }
    UniversalSentenceEncoderQnA.prototype.loadModel = function () {
        return __awaiter(this, void 0, void 0, function () {
            return __generator(this, function (_a) {
                return [2 /*return*/, tfconv.loadGraphModel(BASE_PATH, { fromTFHub: true })];
            });
        });
    };
    UniversalSentenceEncoderQnA.prototype.load = function () {
        return __awaiter(this, void 0, void 0, function () {
            var _a, model, vocabulary;
            return __generator(this, function (_b) {
                switch (_b.label) {
                    case 0: return [4 /*yield*/, Promise.all([
                            this.loadModel(),
                            tokenizer_1.loadVocabulary(BASE_PATH + "/vocab.json?tfjs-format=file")
                        ])];
                    case 1:
                        _a = _b.sent(), model = _a[0], vocabulary = _a[1];
                        this.model = model;
                        this.tokenizer = new tokenizer_1.Tokenizer(vocabulary, RESERVED_SYMBOLS_COUNT);
                        return [2 /*return*/];
                }
            });
        });
    };
    /**
     *
     * Returns a map of queryEmbedding and responseEmbedding
     *
     * @param input the ModelInput that contains queries and answers.
     */
    UniversalSentenceEncoderQnA.prototype.embed = function (input) {
        var _this = this;
        var embeddings = tf.tidy(function () {
            var queryEncoding = _this.tokenizeStrings(input.queries, INPUT_LIMIT);
            var responseEncoding = _this.tokenizeStrings(input.responses, INPUT_LIMIT);
            if (input.contexts != null) {
                if (input.contexts.length !== input.responses.length) {
                    throw new Error('The length of response strings ' +
                        'and context strings need to match.');
                }
            }
            var contexts = input.contexts || [];
            if (input.contexts == null) {
                contexts.length = input.responses.length;
                contexts.fill('');
            }
            var contextEncoding = _this.tokenizeStrings(contexts, INPUT_LIMIT);
            var modelInputs = {};
            modelInputs[QUERY_NODE_NAME] = queryEncoding;
            modelInputs[RESPONSE_NODE_NAME] = responseEncoding;
            modelInputs[RESPONSE_CONTEXT_NODE_NAME] = contextEncoding;
            return _this.model.execute(modelInputs, [QUERY_RESULT_NODE_NAME, RESPONSE_RESULT_NODE_NAME]);
        });
        var queryEmbedding = embeddings[0];
        var responseEmbedding = embeddings[1];
        return { queryEmbedding: queryEmbedding, responseEmbedding: responseEmbedding };
    };
    UniversalSentenceEncoderQnA.prototype.tokenizeStrings = function (strs, limit) {
        var _this = this;
        var tokens = strs.map(function (s) { return _this.shiftTokens(_this.tokenizer.encode(s), INPUT_LIMIT); });
        return tf.tensor2d(tokens, [strs.length, INPUT_LIMIT], 'int32');
    };
    UniversalSentenceEncoderQnA.prototype.shiftTokens = function (tokens, limit) {
        tokens.unshift(TOKEN_START_VALUE);
        for (var index = 0; index < limit; index++) {
            if (index >= tokens.length) {
                tokens[index] = TOKEN_PADDING;
            }
            else if (!SKIP_VALUES.includes(tokens[index])) {
                tokens[index] += OFFSET;
            }
        }
        return tokens.slice(0, limit);
    };
    return UniversalSentenceEncoderQnA;
}());
exports.UniversalSentenceEncoderQnA = UniversalSentenceEncoderQnA;
//# sourceMappingURL=use_qna.js.map