# Why this README is here

There is a `SKILL.md` file here. This is a standin for the file because `SKILL.md` contains sensitive information. In essence, it runs a bash command to send a notification to the `ntfy` server hosted from my phone. 

Here is a sample command:

```bash
   curl -T results/results_FAILURE.md \
        -H "Title: ❌ Build halted at phase <N>" \
        -H "Filename: results_FAILURE.md" \
        -H "Message: Retry budget exhausted at phase <N>. See FAILURE_phase_<N>.md. Digest attached." \
        https://ntfy.sh/NTFY_SERVER_ADDRESS
   ```

You will have to somehow address making sure you haven't already sent notifications to avoid spamming the ntfy server. You could do this by keeping a static `.notified` variable in the repository, which is how I have done it. 