import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from orpheusd.__main__ import guard_middleware


class GuardTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        async def ok(req):
            return web.Response(text="ok")
        app = web.Application(middlewares=[guard_middleware])
        app.router.add_get("/s", ok)
        app.router.add_post("/s", ok)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()

    async def status(self, method="GET", **headers):
        r = await self.client.request(method, "/s", headers=headers)
        return r.status

    async def test_plain_loopback_passes(self):
        # TestServer binds 127.0.0.1:<port>, so the default Host is loopback.
        self.assertEqual(await self.status(), 200)
        self.assertEqual(await self.status("POST"), 200)
        for h in ("localhost", "localhost:47837", "127.0.0.1:1", "[::1]", "[::1]:47837"):
            self.assertEqual(await self.status(Host=h), 200, h)

    async def test_loopback_and_null_origin_pass(self):
        for o in ("http://127.0.0.1:47837", "http://localhost", "http://[::1]:5", "null"):
            self.assertEqual(await self.status("POST", Origin=o), 200, o)
        self.assertEqual(await self.status(**{"Sec-Fetch-Site": "same-origin"}), 200)
        self.assertEqual(await self.status(**{"Sec-Fetch-Site": "none"}), 200)

    async def test_evil_origin_403(self):
        for o in ("https://evil.example", "http://127.0.0.1.evil.com", "http://localhost.evil.com:80", "ftp://127.0.0.1", "garbage"):
            self.assertEqual(await self.status("POST", Origin=o), 403, o)

    async def test_evil_host_403(self):
        for h in ("evil.example", "evil.example:47837", "127.0.0.1.evil.com", "192.168.1.5:47837", "localhost.evil.com"):
            self.assertEqual(await self.status(Host=h), 403, h)

    async def test_cross_site_fetch_403(self):
        for v in ("cross-site", "same-site", "Cross-Site"):
            self.assertEqual(await self.status("POST", **{"Sec-Fetch-Site": v}), 403, v)


if __name__ == "__main__":
    unittest.main()
