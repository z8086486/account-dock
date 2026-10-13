import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from doctor import summarize


class AccountSummaryTests(unittest.TestCase):
    def test_tokens_never_leak_and_email_is_hidden(self):
        result = summarize({'account': {'type': 'chatgpt', 'email': 'test@example.com',
                            'accessToken': 'secret', 'planType': 'plus'}})
        self.assertNotIn('secret', str(result))
        self.assertNotIn('test@example.com', str(result))

    def test_missing_response_is_not_signed_out(self):
        with self.assertRaises(ValueError):
            summarize({})
        self.assertEqual(summarize({'account': None})['status'], 'signed_out')

    def test_api_key_has_no_email(self):
        self.assertEqual(summarize({'account': {'type': 'apiKey'}}),
                         {'status': 'cached_account', 'type': 'apiKey'})


if __name__ == '__main__':
    unittest.main()
