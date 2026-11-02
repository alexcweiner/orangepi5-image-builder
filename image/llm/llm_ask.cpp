// Text in, text out on the RK3588 NPU with a Qwen2.5 Instruct .rkllm: the writer for the dashboard's Project tab.
//
//   llm-ask model.rkllm [max_new_tokens] [context_len]
//
// It loads the model once, then answers requests on stdin until stdin closes, and unloads when it exits:
//   request:  <system>\t<user>\n
//   reply:    ===OPI-LLM=== OK <answer>\n   or   ===OPI-LLM=== ERR <reason>\n
// It prints ===OPI-LLM=== READY once the model is loaded. Every field escapes backslash, newline and tab as
// \\, \n and \t so it stays on one line. Each request stands alone: no earlier answer leaks into the next.
#include <iostream>
#include <string>

#include "rkllm.h"

static const char* kMarker = "===OPI-LLM===";

static std::string escape(const std::string& s)
{
    std::string out;
    for (char c : s) {
        if (c == '\\') out += "\\\\";
        else if (c == '\n') out += "\\n";
        else if (c == '\t') out += "\\t";
        else out += c;
    }
    return out;
}

static std::string unescape(const std::string& s)
{
    std::string out;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] != '\\' || i + 1 == s.size()) { out += s[i]; continue; }
        const char c = s[++i];
        out += c == 'n' ? '\n' : c == 't' ? '\t' : c;
    }
    return out;
}

struct Answer {
    std::string text;
    bool failed = false;
};

static int on_result(RKLLMResult* result, void* userdata, LLMCallState state)
{
    Answer* answer = static_cast<Answer*>(userdata);
    if (state == RKLLM_RUN_NORMAL && result && result->text) answer->text += result->text;
    else if (state == RKLLM_RUN_ERROR) answer->failed = true;
    return 0;
}

int main(int argc, char** argv)
{
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " model.rkllm [max_new_tokens] [context_len]\n";
        return 1;
    }
    RKLLMParam param = rkllm_createDefaultParam();
    param.model_path = argv[1];
    param.max_new_tokens = argc > 2 ? std::atoi(argv[2]) : 256;
    param.max_context_len = argc > 3 ? std::atoi(argv[3]) : 4096;
    param.top_k = 20;
    param.top_p = 0.8f;
    param.temperature = 0.6f;
    param.repeat_penalty = 1.1f;
    param.skip_special_token = true;
    param.is_async = false;
    // The big cores; the little ones keep the camera loop and the map server responsive.
    param.extend_param.base_domain_id = 0;
    param.extend_param.enabled_cpus_num = 4;
    param.extend_param.enabled_cpus_mask = (1u << 4) | (1u << 5) | (1u << 6) | (1u << 7);

    LLMHandle handle = nullptr;
    if (rkllm_init(&handle, &param, on_result) != 0 || handle == nullptr) {
        std::cerr << "failed to load " << argv[1] << "\n";
        return 2;
    }
    std::cout << kMarker << " READY" << std::endl;

    RKLLMInferParam infer = {};
    infer.mode = RKLLM_INFER_GENERATE;
    infer.keep_history = 0;

    std::string line;
    while (std::getline(std::cin, line)) {
        const size_t tab = line.find('\t');
        if (tab == std::string::npos) {
            std::cout << kMarker << " ERR expected <system>\\t<user>" << std::endl;
            continue;
        }
        const std::string system = "<|im_start|>system\n" + unescape(line.substr(0, tab)) + "<|im_end|>\n";
        rkllm_set_chat_template(handle, system.c_str(), "<|im_start|>user\n", "<|im_end|>\n<|im_start|>assistant\n");
        const std::string user = unescape(line.substr(tab + 1));

        RKLLMInput input = {};
        input.role = "user";
        input.input_type = RKLLM_INPUT_PROMPT;
        input.prompt_input = user.c_str();
        Answer answer;
        const int rc = rkllm_run(handle, &input, &infer, &answer);
        if (rc != 0 || answer.failed) std::cout << kMarker << " ERR inference failed (" << rc << ")" << std::endl;
        else std::cout << kMarker << " OK " << escape(answer.text) << std::endl;
    }
    rkllm_destroy(handle);
    return 0;
}
