import unittest

from local_jarvis_linux.openai_client import JarvisOpenAIClient


class OpenAIClientTests(unittest.TestCase):
    def test_extracts_direct_output_text(self):
        output_text = JarvisOpenAIClient._extract_output_text({"output_text": "Done"})

        self.assertEqual(output_text, "Done")

    def test_extracts_nested_responses_api_text(self):
        output_text = JarvisOpenAIClient._extract_output_text(
            {
                "output": [
                    {
                        "content": [
                            {"type": "output_text", "text": '{"action":"wait"}'}
                        ]
                    }
                ]
            }
        )

        self.assertEqual(output_text, '{"action":"wait"}')


if __name__ == "__main__":
    unittest.main()
