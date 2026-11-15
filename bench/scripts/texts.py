# Shared benchmark texts. ASCII-only to avoid PS 5.1 encoding issues.
SHORT = "The quick brown fox jumps over the lazy dog near the riverbank."  # ~62 chars

MEDIUM = (
    "Speech technology has advanced rapidly over the last decade, moving from "
    "clumsy robotic voices to natural sounding synthesis that is hard to tell "
    "apart from a human speaker. Modern systems run efficiently on ordinary "
    "laptops, which means high quality voice output no longer requires a data "
    "center or an expensive graphics card. This shift opens the door to private, "
    "offline assistants that never send your words to the cloud."
)  # ~500 chars

LONG = (
    "The history of computing is a story of relentless miniaturization and rising "
    "ambition. In the early days, a single machine filled an entire room, consumed "
    "as much power as a small town block, and could perform only a few thousand "
    "operations each second. Engineers fed it instructions on punched cards and "
    "waited hours for results that a modern phone would produce instantly. Over "
    "time, vacuum tubes gave way to transistors, and transistors gave way to "
    "integrated circuits packed with millions and then billions of components. "
    "Each generation shrank the hardware while multiplying its capability, a trend "
    "so steady that observers turned it into a law. As machines grew smaller and "
    "faster, software grew richer and more demanding, and the two forces pushed "
    "each other forward in a continuous cycle. Personal computers brought this "
    "power into homes and offices, and networks connected those computers into a "
    "global web of shared information. Today the frontier has moved again, toward "
    "systems that can see, listen, and speak, understanding language and generating "
    "it with startling fluency. These models learn from vast collections of text "
    "and audio, discovering patterns that let them translate between languages, "
    "answer questions, and hold a conversation. Running such systems locally, on "
    "the very device in front of you, was until recently unthinkable, yet the same "
    "miniaturization that shrank the room sized computer now lets a compact neural "
    "network hum along quietly on a thin and light notebook. The implications for "
    "privacy, cost, and accessibility are enormous, because computation that once "
    "demanded a remote server can increasingly happen at the edge, close to the "
    "person it serves. This is the promise that drives a new wave of engineering: "
    "capable, responsive, and private intelligence that lives with you rather than "
    "far away in a distant building full of blinking racks and roaring fans."
)  # ~2000 chars

# ~30 second spoken paragraph for STT ground truth. Around 90 words.
STT_TEXT = (
    "Good morning and welcome to the daily technology briefing. Today we will look "
    "at how small speech models can run entirely on a laptop without any internet "
    "connection. We will measure how quickly they turn text into natural sounding "
    "audio, and how accurately they transcribe recorded speech back into written "
    "words. Our goal is a private assistant that listens, understands, and responds "
    "in real time, using nothing more than the hardware already sitting on your "
    "desk. Let us begin the tests and see what these compact models can really do."
)
