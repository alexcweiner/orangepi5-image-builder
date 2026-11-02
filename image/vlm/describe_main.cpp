// Non-interactive entry point for the InternVL RK3588 demo: one image + one prompt in, one caption out.
// Replaces the upstream interactive src/main.cpp at build time.
//
// With --serve it loads the model once and answers requests on stdin until stdin closes (for command-line clients):
//   request:  <image path>\t<prompt>\n
//   reply:    ===OPI-SERVE=== OK <caption>\n   or   ===OPI-SERVE=== ERR <reason>\n
// Prompts and captions escape backslash, newline and tab as \\, \n and \t so each stays on one line.
#include "RK35llm.h"

static const char* kMarker = "===OPI-DESCRIPTION===";
static const char* kServe = "===OPI-SERVE===";

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

static int serve(const char* vision, const char* llm, int new_tokens, int context_len)
{
    RK35llm vlm;
    vlm.SetInfo(false);
    vlm.SetSilence(true);
    if (!vlm.LoadModel(vision, llm, new_tokens, context_len)) {
        std::cerr << "failed to load " << vision << " / " << llm << "\n";
        return 2;
    }
    // Each request stands alone: no earlier caption leaks into the next.
    vlm.SetHistory(false);
    std::cout << kServe << " READY" << std::endl;

    std::string line;
    while (std::getline(std::cin, line)) {
        const size_t tab = line.find('\t');
        if (tab == std::string::npos) {
            std::cout << kServe << " ERR expected <image>\\t<prompt>" << std::endl;
            continue;
        }
        cv::Mat pic = cv::imread(line.substr(0, tab));
        if (pic.empty()) {
            std::cout << kServe << " ERR could not read image " << escape(line.substr(0, tab)) << std::endl;
            continue;
        }
        vlm.LoadImage(pic);
        const std::string reply = vlm.Ask(std::string("<image>") + unescape(line.substr(tab + 1)));
        const bool bad = reply.find("[Error during inference]") != std::string::npos;
        std::cout << kServe << (bad ? " ERR " : " OK ") << escape(reply) << std::endl;
    }
    return 0;
}

int main(int argc, char** argv)
{
    if (argc >= 4 && std::string(argv[1]) == "--serve")
        return serve(argv[2], argv[3], argc > 4 ? std::atoi(argv[4]) : 256, argc > 5 ? std::atoi(argv[5]) : 4096);
    if (argc < 5) {
        std::cerr << "Usage: " << argv[0] << " image vision.rknn llm.rkllm prompt [max_new_tokens] [context_len]\n"
                  << "       " << argv[0] << " --serve vision.rknn llm.rkllm [max_new_tokens] [context_len]\n";
        return 1;
    }
    const int new_tokens = argc > 5 ? std::atoi(argv[5]) : 256;
    const int context_len = argc > 6 ? std::atoi(argv[6]) : 4096;

    cv::Mat pic = cv::imread(argv[1]);
    if (pic.empty()) {
        std::cerr << "could not read image " << argv[1] << "\n";
        return 3;
    }

    RK35llm vlm;
    vlm.SetInfo(false);
    vlm.SetSilence(true);
    if (!vlm.LoadModel(argv[2], argv[3], new_tokens, context_len)) {
        std::cerr << "failed to load " << argv[2] << " / " << argv[3] << "\n";
        return 2;
    }
    vlm.LoadImage(pic);

    // RK35llm only attaches the image embedding when the prompt contains <image>.
    const std::string reply = vlm.Ask(std::string("<image>") + argv[4]);
    std::cout << "\n" << kMarker << "\n" << reply << std::endl;
    return reply.find("[Error during inference]") == std::string::npos ? 0 : 4;
}
