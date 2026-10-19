from contextlib import redirect_stdout
import io
from pathlib import Path
import tempfile
import tomllib
import unittest
from unittest.mock import patch
import control


class ControlTests(unittest.TestCase):
    def test_reversible_preserves_account_model_and_other_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / 'config.toml'
            original = 'model = "existing-model"\nservice_tier = "fast"\n[features]\nmemories = true\n'
            config.write_text(original)
            with patch.object(control, 'CONFIG', config), patch.object(control, 'ROOT', root), patch.object(control, 'relay'), redirect_stdout(io.StringIO()):
                control.enable()
                parsed = tomllib.loads(config.read_text())
                self.assertEqual(parsed['model'], 'existing-model')
                self.assertNotIn('model_provider', parsed)
                self.assertEqual(parsed['openai_base_url'], 'http://127.0.0.1:47831/backend-api/codex')
                self.assertNotIn('model_providers', parsed)
                # A later unrelated user edit must survive restore.
                config.write_text(config.read_text().replace('memories = true', 'memories = false'))
                control.disable()
                self.assertEqual(config.read_text(), original.replace('memories = true', 'memories = false'))
                self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_enable_explains_that_the_desktop_client_not_only_the_daemon_must_restart(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / 'config.toml'
            config.write_text('model = "existing-model"\n')
            output = io.StringIO()
            with patch.object(control, 'CONFIG', config), patch.object(control, 'ROOT', root), patch.object(control, 'relay'), redirect_stdout(output):
                control.enable()
            self.assertIn('desktop app', output.getvalue())
            self.assertIn('CLI daemon', output.getvalue())

    def test_refuses_implicit_restart_of_legacy_relay(self):
        with patch.object(control, 'health_info', return_value={'service': 'codex-speed-lite', 'version': 1}), patch.object(control.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'explicitly approved restart'):
                control.relay()
            run.assert_not_called()

    def test_refuses_existing_provider(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'config.toml'
            text = 'model_provider = "other"\n'
            config.write_text(text)
            with patch.object(control, 'CONFIG', config):
                with self.assertRaises(RuntimeError):
                    control.enable()
            self.assertEqual(config.read_text(), text)


if __name__ == '__main__':
    unittest.main()
