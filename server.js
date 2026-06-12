import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import Stripe from "stripe";
import { initializeApp, cert } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

// IP rate limiting за guest потребители
const ipUsage = {};
const GUEST_LIMIT = 5;
const FREE_ACCOUNT_LIMIT = 5;
const WHITELIST_IPS = ["84.40.105.147"];

function getClientIP(req) {
  return (
    req.headers["x-forwarded-for"]?.split(",")[0] || req.socket.remoteAddress
  );
}

dotenv.config();

/* =========================
   FIREBASE ADMIN INIT
========================= */
const privateKey = (process.env.FIREBASE_PRIVATE_KEY || "")
  .replace(/\\n/g, "\n")
  .replace(/^"|"$/g, "");

initializeApp({
  credential: cert({
    projectId: process.env.FIREBASE_PROJECT_ID,
    clientEmail: process.env.FIREBASE_CLIENT_EMAIL,
    privateKey,
  }),
});

const db = getFirestore();

/* =========================
   EXPRESS SETUP
========================= */
const app = express();

app.use(cors());
app.use("/webhook", express.raw({ type: "application/json" }));
app.use(express.json());
app.use(express.static("public"));

app.get("/", (req, res) => {
  res.send("Server is running ✔");
});

/* =========================
   ENV
========================= */
const API_KEY = process.env.CLAUDE_API_KEY;
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET;

console.log("API KEY EXISTS:", !!API_KEY);
console.log("WEBHOOK SECRET EXISTS:", !!WEBHOOK_SECRET);

/* =========================
   STRIPE PRICE IDS
========================= */
const PRICES = {
  monthly: "price_1Tear5AQoQFQDVwfVyXdWWIW",
  yearly: "price_1TeasCAQoQFQDVwfhlx1KXqU",
};

/* =========================
   STRIPE CHECKOUT
========================= */
app.post("/create-checkout-session", async (req, res) => {
  try {
    const { plan, uid, email } = req.body;
    console.log("CHECKOUT REQUEST:", { plan, uid, email });

    if (!PRICES[plan]) {
      return res.status(400).json({ error: "Invalid plan selected" });
    }

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer_email: email,
      metadata: { uid, plan },
      line_items: [{ price: PRICES[plan], quantity: 1 }],
      success_url:
        "https://reviewreply-production-c63d.up.railway.app?success=true",
      cancel_url:
        "https://reviewreply-production-c63d.up.railway.app?cancel=true",
    });

    res.json({ url: session.url });
  } catch (err) {
    console.error("STRIPE ERROR:", err.message);
    res.status(500).json({ error: err.message });
  }
});

/* =========================
   STRIPE WEBHOOK
========================= */
app.post("/webhook", async (req, res) => {
  const sig = req.headers["stripe-signature"];
  let event;

  try {
    event = stripe.webhooks.constructEvent(req.body, sig, WEBHOOK_SECRET);
  } catch (err) {
    console.error("WEBHOOK SIGNATURE FAILED:", err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  console.log("WEBHOOK EVENT:", event.type);

  if (event.type === "checkout.session.completed") {
    const session = event.data.object;
    const uid = session.metadata?.uid;
    const customerId = session.customer;

    if (uid) {
      try {
        await db.collection("users").doc(uid).update({
          isPremium: true,
          stripeCustomerId: customerId,
        });
        console.log(`✅ User ${uid} upgraded to Premium`);
      } catch (err) {
        console.error("FIRESTORE UPDATE FAILED:", err);
      }
    }
  }

  if (event.type === "customer.subscription.deleted") {
    const subscription = event.data.object;
    const customerId = subscription.customer;

    try {
      const snapshot = await db
        .collection("users")
        .where("stripeCustomerId", "==", customerId)
        .get();

      snapshot.forEach(async (docSnap) => {
        await docSnap.ref.update({ isPremium: false });
        console.log(`❌ User ${docSnap.id} downgraded to Free`);
      });
    } catch (err) {
      console.error("FIRESTORE DOWNGRADE FAILED:", err);
    }
  }

  res.json({ received: true });
});

/* =========================
   MONTHLY RESET
========================= */
async function checkAndResetUsage(uid) {
  const ref = db.collection("users").doc(uid);
  const snap = await ref.get();
  const data = snap.data();

  if (!data) return;

  const lastReset = data.lastReset ? new Date(data.lastReset) : new Date(0);
  const now = new Date();

  const differentMonth =
    now.getMonth() !== lastReset.getMonth() ||
    now.getFullYear() !== lastReset.getFullYear();

  if (differentMonth) {
    await ref.update({ usageCount: 0, lastReset: now.toISOString() });
    console.log(`✅ Reset usage for user ${uid}`);
  }
}

/* =========================
   AI REPLY
========================= */
app.post("/api/reply", async (req, res) => {
  console.log("HANDLER STARTED");
  console.log("BODY:", req.body);

  try {
    const { review, tone, uid, rating, lang } = req.body;
    const ip = getClientIP(req);

    // Whitelist - без лимит
    if (!WHITELIST_IPS.includes(ip)) {
      if (uid) {
        // Логнат потребител
        await checkAndResetUsage(uid);
        const ref = db.collection("users").doc(uid);
        const snap = await ref.get();
        const userData = snap.data();

        if (!userData) {
          return res.status(400).json({ error: "User not found" });
        }

        // Premium - неограничено
        if (!userData.isPremium) {
          // Безплатен акаунт - 5 на месец
          if ((userData.usageCount || 0) >= FREE_ACCOUNT_LIMIT) {
            return res.status(429).json({ error: "limit_reached" });
          }
          await ref.update({ usageCount: (userData.usageCount || 0) + 1 });
        }
      } else {
        // Guest - 5 по IP
        ipUsage[ip] = ipUsage[ip] || 0;
        if (ipUsage[ip] >= GUEST_LIMIT) {
          return res.status(429).json({ error: "limit_reached" });
        }
        ipUsage[ip]++;
      }
    }

    if (!review) {
      return res.status(400).json({ error: "Review required" });
    }

    const langText =
      lang === "bg"
        ? "Reply in Bulgarian language."
        : "Reply in English language.";

    const prompt = `You are a business owner replying to a Google review.

Tone: ${tone || "friendly"}
Rating: ${rating || 5} out of 5 stars
${langText}

Rules:
- natural human tone
- 1-2 sentences max
- no emojis

Review:
${review}`;

    let response;
    try {
      response = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "x-api-key": API_KEY,
          "anthropic-version": "2023-06-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          model: "claude-haiku-4-5-20251001",
          max_tokens: 200,
          messages: [{ role: "user", content: prompt }],
        }),
      });
    } catch (err) {
      console.error("FETCH FAILED:", err);
      return res.status(500).json({ error: "Failed to reach Claude API" });
    }

    const raw = await response.text();

    if (!response.ok) {
      return res.status(500).json({ error: "Claude API failed", raw });
    }

    let data;
    try {
      data = JSON.parse(raw);
    } catch (err) {
      return res.status(500).json({ error: "Invalid JSON from Claude", raw });
    }

    const reply = data?.content?.[0]?.text;
    if (!reply) {
      return res.status(500).json({ error: "No reply generated" });
    }

    return res.json({ reply });
  } catch (err) {
    console.error("SERVER CRASH:", err);
    return res.status(500).json({ error: err.message });
  }
});

/* =========================
   START SERVER
========================= */
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
