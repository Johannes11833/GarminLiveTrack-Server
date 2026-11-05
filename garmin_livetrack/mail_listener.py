import datetime
import email
import os
import re
import time
from typing import Callable
from imapclient import IMAPClient
import imapclient as imapclient
import requests
from dotenv import load_dotenv

from garmin_livetrack.logger import configure_logs, get_logger

logger = get_logger(__name__)

# Load .env before reading configuration so values from the file take effect.
load_dotenv()

# Base URL of the LiveTrack REST API. Override when the listener runs in a
# different container than the API, e.g. LIVETRACK_API_URL=http://garmin-livetrack-api:8000
API_URL = os.getenv("LIVETRACK_API_URL", "http://127.0.0.1:8000")
# Shared secret proving this is the trusted email listener; must match the
# API's LIVETRACK_API_TOKEN, otherwise the API rejects /trackings requests.
API_TOKEN = os.getenv("LIVETRACK_API_TOKEN", "")


def start_session(url: str):
    """Feed the LiveTrack URL from the email listener to the API, which then
    starts tracking the session and notifies registered devices."""
    for attempt in range(3):
        try:
            response = requests.post(
                f"{API_URL}/trackings",
                json={"url": url},
                headers={"Authorization": f"Bearer {API_TOKEN}"},
                timeout=15,
            )
            if response.status_code == 201:
                print(f"Session started via API: {url}")
                return
            print(
                f"Failed to start session (HTTP {response.status_code}): "
                f"{response.text[:200]}"
            )
        except Exception as error:
            print(f"Failed to reach API at {API_URL}: {error}")
        time.sleep(5 * (attempt + 1))


class GarminLinkListener:
    """Watches an IMAP inbox for Garmin LiveTrack emails.

    IDLE push notices alone are not reliable: a notice can be lost (the
    server never sends it, or it arrives on a connection that is already
    half-dead), and the server announces each new message only once. So the
    listener ends every IDLE wait after ``check_interval_s`` and searches the
    inbox either way, which bounds how late a LiveTrack email can be noticed
    and also detects a dead connection, because the search fails on it.
    """

    def __init__(
        self,
        host: str,
        username: str,
        password: str,
        # How long to wait in IDLE before searching anyway. Each search reuses
        # the open connection; only reconnects count as logins.
        check_interval_s: int = 2 * 60,
        # Wait before the first login retry after a failed login; doubles on
        # every further failure up to reconnect_max_delay_s.
        reconnect_initial_delay_s: float = 10,
        reconnect_max_delay_s: float = 10 * 60,
        callback: Callable[[str], None] | None = None,
    ):
        """
        Optionally register a callback function that takes a single string argument.
        """
        self.host = host
        self.username = username
        self.password = password
        self.check_interval_s = check_interval_s
        self.reconnect_initial_delay_s = reconnect_initial_delay_s
        self.reconnect_max_delay_s = reconnect_max_delay_s
        self.callback = callback

        self.client: IMAPClient | None = None

    def __extract_garmin_link(self, msg) -> str | None:
        """
        Extracts a Garmin LiveTrack link from an HTML email.
        Returns the link as a string or None if not found.
        """
        html_content = ""

        # Get HTML part of the email
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == "text/html":
                    charset = part.get_content_charset() or "utf-8"
                    html_content += part.get_payload(decode=True).decode(
                        charset, errors="ignore"
                    )
                    break
        else:
            if msg.get_content_type() == "text/html":
                charset = msg.get_content_charset() or "utf-8"
                html_content = msg.get_payload(decode=True).decode(
                    charset, errors="ignore"
                )

        if not html_content:
            return None

        # Regex to match Garmin LiveTrack links
        pattern = r"https://livetrack\.garmin\.com/[\w\-/\?\=&%]+"
        match = re.search(pattern, html_content)

        if match:
            return match.group(0)

        return None

    def __process_unseen_garmin_messages(self) -> bool:
        """Searches for unread Garmin emails from today and hands the latest
        LiveTrack link to the callback. Returns True if a link was found.
        IMAP errors propagate to the caller, which reconnects."""
        logger.debug("Searching for new Garmin messages.")
        today = datetime.date.today().strftime("%d-%b-%Y")

        # search for garmin livetrack emails from today
        messages = self.client.search(
            [
                "UNSEEN",
                "SINCE",
                today,
                "FROM",
                "noreply@garmin.com",
            ]
        )
        if not messages:
            logger.debug("No new Garmin messages found.")
            return False
        response = self.client.fetch(messages, "RFC822")

        # iterate over the found emails, latest first
        for uid, message_data in reversed(response.items()):
            msg = email.message_from_bytes(message_data[b"RFC822"])
            logger.info(
                f"Found email from {msg.get("From")} with subject {msg.get("Subject")}"
            )
            link = self.__extract_garmin_link(msg)

            try:
                # Add the \Seen flag so we won't accidentally process this message again
                self.client.add_flags(uid, [imapclient.SEEN])
            except Exception:
                logger.warning("Failed to mark Garmin email as seen!")

            if link:
                if self.callback:
                    self.callback(link)
                return True  # latest link found!

        logger.info("No new Garmin email found")
        return False

    def connect(self):
        if self.client:
            try:
                self.client.logout()
                logger.info("Logged out.")
            except Exception:
                # Expected after the server dropped the connection.
                logger.debug("Logout failed (connection already closed).")
            self.client = None

        self.client = IMAPClient(host=self.host)
        self.client.login(self.username, self.password)
        logger.info(f"Successfully logged in to: {self.username}")
        self.client.select_folder("INBOX", readonly=False)

    def reconnect(self):
        """Logs in again right away; only waits (with exponential backoff)
        while logins keep failing, so a dropped connection costs seconds but
        a persistent outage doesn't hammer the server."""
        delay = self.reconnect_initial_delay_s
        while True:
            try:
                self.connect()
                return
            except Exception as e:
                logger.warning(f"Login failed: {e}. Retrying in {delay:.0f}s.")
                time.sleep(delay)
                delay = min(delay * 2, self.reconnect_max_delay_s)

    def __wait_for_notice(self) -> bool:
        """IDLEs for up to check_interval_s. Returns True if the server
        announced a new message, either while idling or in the responses
        that arrive while ending IDLE."""
        self.client.idle()
        responses = self.client.idle_check(timeout=self.check_interval_s)
        _, done_responses = self.client.idle_done()
        logger.debug(f"Server sent: {responses or 'nothing'} / {done_responses or 'nothing'}")
        return self.__check_responses(responses) or self.__check_responses(
            done_responses
        )

    def __handle_new_mail_notice(self) -> None:
        # The notice can come before the message is fully stored, so retry
        # the search a few times before giving up.
        time.sleep(10)
        for _ in range(0, 10):
            if self.__process_unseen_garmin_messages():
                return
            delay_s = 15
            logger.info(f"Waiting {delay_s}s before searching again.")
            time.sleep(delay_s)

    def start(self):
        self.reconnect()
        logger.info(
            f"Listening for new Garmin emails (IDLE, plus a search every "
            f"{self.check_interval_s}s)."
        )

        # Catch emails that arrived while the listener was down.
        try:
            self.__process_unseen_garmin_messages()
        except Exception as e:
            logger.warning(f"Initial search failed: {e}")
            self.reconnect()

        # Back-off for errors that keep coming right after a successful
        # login (server accepts logins but drops every command), so that
        # case can't turn into a tight reconnect loop.
        error_delay = self.reconnect_initial_delay_s
        consecutive_errors = 0
        while True:
            try:
                if self.__wait_for_notice():
                    logger.info("Server announced new mail.")
                    self.__handle_new_mail_notice()
                else:
                    # Periodic search: catches emails whose notice was lost.
                    self.__process_unseen_garmin_messages()
                consecutive_errors = 0
                error_delay = self.reconnect_initial_delay_s
            except Exception as e:
                logger.warning(f"IMAP connection error: {e}. Reconnecting.")
                if consecutive_errors:
                    logger.info(f"Repeated errors; waiting {error_delay:.0f}s first.")
                    time.sleep(error_delay)
                    error_delay = min(error_delay * 2, self.reconnect_max_delay_s)
                consecutive_errors += 1
                self.reconnect()
                try:
                    self.__process_unseen_garmin_messages()
                except Exception as e:
                    logger.warning(f"Search after reconnect failed: {e}")

    def __check_responses(self, responses) -> bool:
        if responses:
            for response in responses:
                if len(response) >= 2 and response[1] == b"EXISTS":
                    return True
        return False


def cli():
    # email secrets
    HOST = os.getenv("LIVETRACK_EMAIL_HOST")
    USERNAME = os.getenv("LIVETRACK_EMAIL_USERNAME")
    PASSWORD = os.getenv("LIVETRACK_EMAIL_PASSWORD")

    configure_logs()

    # Setup the garmin livetrack email listener
    listener = GarminLinkListener(
        host=HOST, username=USERNAME, password=PASSWORD, callback=start_session
    )
    listener.start()


if __name__ == "__main__":
    cli()
