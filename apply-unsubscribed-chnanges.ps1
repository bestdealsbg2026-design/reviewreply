# Run this from inside C:\Users\dimit\Desktop\reviewreply-v2
# It writes the updated files directly to disk, then commits and pushes.

$ErrorActionPreference = "Stop"

$serverJs = @'
import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import Stripe from "stripe";
import admin from "firebase-admin";

dotenv.config();

const app = express();

/* =========================
   FIREBASE ADMIN INIT
   (server-side only — full trusted access,
   bypasses Firestore security rules by design)
========================= */
admin.initializeApp({
  credential: admin.credential.cert({
    project_id: process.env.FIREBASE_PROJECT_ID,
    client_email: process.env.FIREBASE_CLIENT_EMAIL,
    // Railway/Render env vars often escape newlines as \n in the literal string
    private_key: process.env.FIREBASE_PRIVATE_KEY?.replace(/\\n/g, "\n"),
  }),
});

const dbAdmin = admin.firestore();

/* =========================
   ENV
========================= */
const API_KEY = process.env.CLAUDE_API_KEY;
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;

console.log("API KEY EXISTS:", !!API_KEY);

app.use(cors());

/* =========================
   STRIPE WEBHOOK
   MUST use raw body — registered BEFORE express.json()
   so Stripe's signature check can verify the exact bytes sent.
========================= */
app.post(
  "/webhook/stripe",
  express.raw({ type: "application/json" }),
  async (req, res) => {
    const sig = req.headers["stripe-signature"];
    let event;

    try {
      event = stripe.webhooks.constructEvent(req.body, sig, webhookSecret);
    } catch (err) {
      console.error("WEBHOOK SIGNATURE VERIFICATION FAILED:", err.message);
      return res.status(400).send(`Webhook Error: ${err.message}`);
    }

    try {
      switch (event.type) {
        case "checkout.session.completed": {
          const session = event.data.object;
          const uid = session.metadata?.uid;

          if (uid) {
            await dbAdmin.collection("users").doc(uid).set(
              {
                isPremium: true,
                stripeCustomerId: session.customer,
                stripeSubscriptionId: session.subscription,
                cancelAtPeriodEnd: false,
              },
              { merge: true },
            );
            console.log("PREMIUM GRANTED:", uid);
          } else {
            console.warn("checkout.session.completed with no uid in metadata");
          }
          break;
        }

        case "customer.subscription.deleted":
        case "customer.subscription.updated": {
          const subscription = event.data.object;
          const isActive = subscription.status === "active";

          // find the user by stripeCustomerId
          const snap = await dbAdmin
            .collection("users")
            .where("stripeCustomerId", "==", subscription.customer)
            .limit(1)
            .get();

          if (!snap.empty) {
            await snap.docs[0].ref.set(
              { isPremium: isActive },
              { merge: true },
            );
            console.log(
              "SUBSCRIPTION UPDATED:",
              subscription.customer,
              "active:",
              isActive,
            );
          }
          break;
        }

        default:
          // ignore other event types
          break;
      }

      res.json({ received: true });
    } catch (err) {
      console.error("WEBHOOK HANDLER ERROR:", err);
      res.status(500).json({ error: err.message });
    }
  },
);

/* Regular JSON parsing for everything else, registered AFTER the webhook route */
app.use(express.json());
app.use(express.static("public"));

app.get("/", (req, res) => {
  res.send("Server is running ✔");
});

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

    console.log("CHECKOUT REQUEST:", {
      plan,
      uid,
      email,
    });

    if (!PRICES[plan]) {
      return res.status(400).json({
        error: "Invalid plan selected",
      });
    }

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",

      customer_email: email,

      metadata: {
        uid,
        plan,
      },

      line_items: [
        {
          price: PRICES[plan],
          quantity: 1,
        },
      ],

      success_url: `${process.env.APP_URL}?success=true`,
      cancel_url: `${process.env.APP_URL}?cancel=true`,
    });

    res.json({
      url: session.url,
    });
  } catch (err) {
    console.error("STRIPE ERROR:", err);

    res.status(500).json({
      error: err.message,
    });
  }
});

/* =========================
   CANCEL SUBSCRIPTION (AT PERIOD END)
   Only for logged-in users with an active subscription.
   Sets cancel_at_period_end so the user keeps premium
   access through the remainder of the billing period they
   already paid for; Stripe fires customer.subscription.deleted
   at the end of the period, which the webhook above already
   handles by flipping isPremium to false.
========================= */
app.post("/cancel-subscription", async (req, res) => {
  try {
    const { uid } = req.body;

    if (!uid) {
      return res.status(400).json({ error: "uid required" });
    }

    const userRef = dbAdmin.collection("users").doc(uid);
    const userDoc = await userRef.get();

    if (!userDoc.exists) {
      return res.status(404).json({ error: "User not found" });
    }

    const { stripeSubscriptionId, isPremium, cancelAtPeriodEnd } =
      userDoc.data();

    if (!isPremium || !stripeSubscriptionId) {
      return res.status(400).json({
        error: "No active subscription found for this account",
      });
    }

    if (cancelAtPeriodEnd) {
      return res.status(409).json({
        error: "Subscription is already scheduled to cancel",
        currentPeriodEnd: userDoc.data().currentPeriodEnd ?? null,
      });
    }

    const subscription = await stripe.subscriptions.update(
      stripeSubscriptionId,
      { cancel_at_period_end: true },
    );

    // Newer Stripe API versions moved current_period_end from the
    // subscription object down to the subscription item level.
    const currentPeriodEnd =
      subscription.current_period_end ??
      subscription.items?.data?.[0]?.current_period_end ??
      null;

    // Reflect the pending cancellation immediately in Firestore so the
    // UI can show "access until <date>" without waiting on the webhook.
    // isPremium stays true — access continues until the period actually ends.
    await userRef.set(
      {
        cancelAtPeriodEnd: true,
        currentPeriodEnd,
      },
      { merge: true },
    );

    res.json({
      canceled: true,
      currentPeriodEnd,
    });
  } catch (err) {
    console.error("CANCEL SUBSCRIPTION ERROR:", err);

    res.status(500).json({
      error: err.message,
    });
  }
});

/* =========================
   ANONYMOUS IP RATE LIMIT
   Tracks free-trial usage by IP in Firestore so it
   survives cache-clearing/incognito. Server-trusted,
   so it can't be bypassed by editing client JS.
========================= */
const ANON_FREE_LIMIT = 5;
const EXEMPT_IPS = ["84.40.105.147"];

function getClientIp(req) {
  const forwarded = req.headers["x-forwarded-for"];
  if (forwarded) return forwarded.split(",")[0].trim();
  return req.socket.remoteAddress || "unknown";
}

async function checkAnonRateLimit(req, res, next) {
  // Only applies to requests that don't carry a logged-in uid.
  // The frontend only sends uid-based checks via Firestore for
  // logged-in users, so anonymous requests are identified simply
  // by absence of an Authorization/uid context — here we rate-limit
  // by IP regardless, but logged-in users are already capped
  // client-side via Firestore usageCount, so this is a safety net
  // specifically for anonymous abuse.
  const ip = getClientIp(req);

  if (EXEMPT_IPS.includes(ip)) {
    return next();
  }

  const { uid } = req.body || {};
  if (uid) {
    // Logged-in request — handled by Firestore usageCount in the frontend.
    return next();
  }

  try {
    const ref = dbAdmin.collection("anonIpUsage").doc(ip);
    const snap = await ref.get();
    const count = snap.exists ? snap.data().count || 0 : 0;

    if (count >= ANON_FREE_LIMIT) {
      return res.status(403).json({
        error: "FREE_LIMIT_REACHED",
        message: "Free trial limit reached. Please register to continue.",
      });
    }

    await ref.set(
      { count: count + 1, lastUsed: new Date().toISOString() },
      { merge: true },
    );

    next();
  } catch (err) {
    console.error("RATE LIMIT CHECK FAILED:", err);
    // Fail open rather than blocking legitimate users if Firestore hiccups
    next();
  }
}

/* =========================
   AI REPLY
========================= */
app.post("/api/reply", checkAnonRateLimit, async (req, res) => {
  console.log("HANDLER STARTED");

  try {
    const { review, tone } = req.body;

    if (!review) {
      return res.status(400).json({
        error: "Review required",
      });
    }

    const prompt = `
You are a business owner replying to a Google review.

Tone: ${tone || "friendly"}

Rules:
- Reply in the SAME language as the review below. If the review is in Bulgarian, reply only in Bulgarian. If it's in English, reply only in English. Never mix languages or provide more than one language.
- natural human tone
- 1–2 sentences max
- no emojis

Review:
${review}
`;

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
          model: "claude-sonnet-4-6",
          max_tokens: 200,
          messages: [
            {
              role: "user",
              content: prompt,
            },
          ],
        }),
      });
    } catch (err) {
      console.error("FETCH FAILED:", err);

      return res.status(500).json({
        error: "Failed to reach Claude API",
      });
    }

    console.log("FETCH DONE");
    console.log("STATUS:", response.status);

    const raw = await response.text();

    console.log("RAW RESPONSE:", raw);

    if (!response.ok) {
      return res.status(500).json({
        error: "Claude API failed",
        raw,
      });
    }

    let data;

    try {
      data = JSON.parse(raw);
    } catch (err) {
      return res.status(500).json({
        error: "Invalid JSON from Claude",
        raw,
      });
    }

    const reply = data?.content?.[0]?.text;

    if (!reply) {
      return res.status(500).json({
        error: "No reply generated",
        data,
      });
    }

    return res.json({
      reply,
    });
  } catch (err) {
    console.error("SERVER CRASH:", err);

    return res.status(500).json({
      error: err.message,
    });
  }
});

/* =========================
   START SERVER
========================= */
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
'@

$indexHtml = @'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>ReviewReply AI</title>
    <link
      rel="stylesheet"
      href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.29.0/dist/tabler-icons.min.css"
    />
    <style>
      * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
      }
      body {
        background: #070710;
        color: #fff;
        font-family: "Times New Roman", Times, serif;
        font-weight: 400;
        overflow-x: hidden;
        max-width: 100vw;
      }
      .rr-nav {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 18px 40px;
        border-bottom: 0.5px solid rgba(255, 255, 255, 0.08);
        background: rgba(7, 7, 16, 0.95);
        position: sticky;
        top: 0;
        z-index: 100;
      }
      .nav-left {
        display: flex;
        align-items: center;
        gap: 16px;
      }
      .rr-logo {
        font-size: 28px;
        font-weight: 500;
        color: #fff;
        letter-spacing: -0.5px;
      }
      .rr-logo span {
        color: #8b5cf6;
      }
      .nav-actions {
        display: flex;
        gap: 14px;
        align-items: center;
      }
      .nav-btn {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        height: 36px;
        width: 108px;
        border-radius: 8px;
        font-size: 14px;
        font-weight: 500;
        cursor: pointer;
        font-family: "Times New Roman", Times, serif;
      }
      .nav-btn.outline {
        background: transparent;
        border: 1px solid rgba(255, 255, 255, 0.3);
        color: #fff;
      }
      #logoutBtn {
        background: #8b5cf6 !important;
        border: 1px solid #8b5cf6 !important;
        color: #fff !important;
      }
      .nav-btn.filled {
        background: #8b5cf6;
        border: 1px solid #8b5cf6;
        color: #fff;
      }
      .nav-email {
        font-size: 16px;
        background: linear-gradient(135deg, #f59e0b, #ec4899);
        -webkit-background-clip: text;
        -webkit-text-fill-color: transparent;
        background-clip: text;
        font-weight: 500;
      }
      .nav-plan {
        font-size: 12px;
        font-weight: 600;
        padding: 4px 10px;
        border-radius: 20px;
      }
      .nav-plan.free {
        padding: 4px 10px;
        border-radius: 20px;
        background: linear-gradient(135deg, #f59e0b, #ec4899) !important;
        -webkit-background-clip: text !important;
        -webkit-text-fill-color: transparent !important;
        background-clip: text !important;
        border: 0.5px solid rgba(236, 72, 153, 0.3) !important;
        font-weight: 600;
      }
      .nav-plan.premium {
        background: rgba(251, 191, 36, 0.15);
        color: #fbbf24;
        border: 0.5px solid rgba(251, 191, 36, 0.3);
      }
      .auth-message {
        display: none;
        text-align: center;
        max-width: 600px;
        margin: 12px auto 0;
        padding: 12px 20px;
        border-radius: 10px;
        font-size: 14px;
        font-weight: 500;
      }
      .auth-message.show {
        display: block;
      }
      .auth-message.success {
        background: rgba(34, 197, 94, 0.15);
        border: 0.5px solid rgba(34, 197, 94, 0.4);
        color: #86efac;
      }
      .auth-message.error {
        background: rgba(239, 68, 68, 0.15);
        border: 0.5px solid rgba(239, 68, 68, 0.4);
        color: #fca5a5;
      }

      /* LANG SWITCHER */
      .lang-switcher {
        display: flex;
        gap: 4px;
        background: rgba(255, 255, 255, 0.06);
        border: 0.5px solid rgba(255, 255, 255, 0.12);
        border-radius: 8px;
        padding: 3px;
      }
      .lang-btn {
        background: transparent;
        border: none;
        color: rgba(255, 255, 255, 0.5);
        font-size: 13px;
        font-weight: 600;
        cursor: pointer;
        padding: 4px 10px;
        border-radius: 6px;
        font-family: "Times New Roman", Times, serif;
        transition: 0.2s;
      }
      .lang-btn.active {
        background: #8b5cf6;
        color: #fff;
      }

      .rr-hero {
        text-align: center;
        padding: 80px 40px 60px;
        max-width: 720px;
        margin: 0 auto;
        position: relative;
      }
      .hero-glow {
        position: absolute;
        top: 0;
        left: 50%;
        transform: translateX(-50%);
        width: 600px;
        height: 300px;
        background: radial-gradient(
          ellipse at center,
          rgba(139, 92, 246, 0.2) 0%,
          rgba(59, 130, 246, 0.1) 40%,
          transparent 70%
        );
        pointer-events: none;
      }
      .rr-badge {
        display: inline-block;
        background: rgba(139, 92, 246, 0.12);
        border: 0.5px solid rgba(139, 92, 246, 0.35);
        color: #c4b5fd;
        font-size: 12px;
        padding: 6px 14px;
        border-radius: 100px;
        margin-bottom: 24px;
        position: relative;
      }
      .rr-hero h1 {
        font-size: 48px;
        font-weight: 500;
        line-height: 1.15;
        letter-spacing: -1px;
        margin-bottom: 20px;
        color: #fff;
        position: relative;
      }
      .grad-text {
        background: linear-gradient(90deg, #818cf8, #a78bfa, #e879f9);
        -webkit-background-clip: text;
        -webkit-text-fill-color: transparent;
        background-clip: text;
      }
      .rr-hero p {
        font-size: 16px;
        color: rgba(255, 255, 255, 0.5);
        line-height: 1.7;
        margin-bottom: 36px;
        position: relative;
      }
      .rr-hero-btns {
        display: flex;
        gap: 20px;
        justify-content: center;
        flex-wrap: wrap;
        position: relative;
      }
      .btn-hero {
        background: linear-gradient(135deg, #8b5cf6, #6366f1);
        border: none;
        color: #fff;
        padding: 0;
        border-radius: 10px;
        font-size: 15px;
        cursor: pointer;
        font-weight: 500;
        height: 38px;
        width: 160px;
        font-family: "Times New Roman", Times, serif;
      }
      .btn-hero-outline {
        background: transparent;
        border: 0.5px solid rgba(255, 255, 255, 0.25);
        color: rgba(255, 255, 255, 0.8);
        padding: 0;
        border-radius: 10px;
        font-size: 15px;
        cursor: pointer;
        height: 42px;
        width: 160px;
        font-family: "Times New Roman", Times, serif;
      }

      .rr-demo {
        margin: 0 auto 60px;
        max-width: 680px;
        padding: 0 40px;
      }
      .demo-inner {
        background: rgba(255, 255, 255, 0.03);
        border: 0.5px solid rgba(255, 255, 255, 0.08);
        border-radius: 16px;
        padding: 28px;
        position: relative;
        overflow: hidden;
      }
      .demo-inner::before {
        content: "";
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        height: 1px;
        background: linear-gradient(
          90deg,
          transparent,
          rgba(139, 92, 246, 0.6),
          rgba(99, 102, 241, 0.6),
          transparent
        );
      }
      .demo-label {
        font-size: 11px;
        color: rgba(255, 255, 255, 0.3);
        text-transform: uppercase;
        letter-spacing: 1px;
        margin-bottom: 12px;
      }
      .demo-review {
        background: rgba(255, 255, 255, 0.05);
        border: 0.5px solid rgba(255, 255, 255, 0.08);
        border-radius: 10px;
        padding: 14px;
        font-size: 16px;
        color: rgba(255, 255, 255, 0.65);
        margin-bottom: 14px;
        line-height: 1.6;
      }
      .demo-stars {
        color: #f59e0b;
        font-size: 14px;
        margin-bottom: 6px;
      }
      .demo-arrow {
        text-align: center;
        color: #8b5cf6;
        font-size: 20px;
        margin: 10px 0;
      }
      .demo-reply {
        background: rgba(139, 92, 246, 0.08);
        border: 0.5px solid rgba(139, 92, 246, 0.25);
        border-radius: 10px;
        padding: 14px;
        font-size: 16px;
        color: rgba(255, 255, 255, 0.75);
        line-height: 1.6;
      }
      .demo-reply-label {
        font-size: 10px;
        color: #a78bfa;
        font-weight: 500;
        margin-bottom: 8px;
        text-transform: uppercase;
        letter-spacing: 0.8px;
      }

      .rr-stats {
        max-width: 680px;
        margin: 0 auto 60px;
        padding: 0 40px;
      }
      .stats-box {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        background: rgba(255, 255, 255, 0.04);
        border: 0.5px solid rgba(255, 255, 255, 0.1);
        border-radius: 16px;
        overflow: hidden;
      }
      .stat-item {
        text-align: center;
        padding: 32px 20px;
        border-right: 0.5px solid rgba(255, 255, 255, 0.08);
      }
      .stat-item:last-child {
        border-right: none;
      }
      .stat-num {
        font-size: 36px;
        font-weight: 300;
        letter-spacing: -1px;
        background: linear-gradient(135deg, #818cf8, #e879f9);
        -webkit-background-clip: text;
        -webkit-text-fill-color: transparent;
        background-clip: text;
      }
      .stat-label {
        font-size: 12px;
        color: rgba(255, 255, 255, 0.35);
        margin-top: 4px;
      }

      .rr-features {
        padding: 0 40px 60px;
        max-width: 760px;
        margin: 0 auto;
      }
      .section-title {
        text-align: center;
        font-size: 28px;
        font-weight: 500;
        color: #fff;
        margin-bottom: 8px;
        letter-spacing: -0.5px;
      }
      .section-sub {
        text-align: center;
        font-size: 14px;
        color: rgba(255, 255, 255, 0.35);
        margin-bottom: 32px;
      }
      .features-grid {
        display: grid;
        grid-template-columns: repeat(2, 1fr);
        gap: 14px;
      }
      .feature-card {
        background: rgba(255, 255, 255, 0.03);
        border: 0.5px solid rgba(255, 255, 255, 0.07);
        border-radius: 14px;
        padding: 22px;
        position: relative;
        overflow: hidden;
      }
      .feature-card::before {
        content: "";
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        height: 1px;
        background: linear-gradient(
          90deg,
          transparent,
          rgba(139, 92, 246, 0.4),
          transparent
        );
      }
      .feature-icon {
        width: 38px;
        height: 38px;
        background: rgba(139, 92, 246, 0.12);
        border-radius: 10px;
        display: flex;
        align-items: center;
        justify-content: center;
        margin-bottom: 12px;
        color: #a78bfa;
        font-size: 18px;
      }
      .feature-title {
        font-size: 15px;
        font-weight: 500;
        color: #fff;
        margin-bottom: 6px;
      }
      .feature-desc {
        font-size: 13px;
        color: rgba(255, 255, 255, 0.4);
        line-height: 1.6;
      }

      .rr-reviews {
        padding: 0 40px 60px;
        max-width: 760px;
        margin: 0 auto;
      }
      .reviews-grid {
        display: grid;
        grid-template-columns: repeat(2, 1fr);
        gap: 14px;
        margin-top: 32px;
      }
      .review-card {
        background: rgba(255, 255, 255, 0.03);
        border: 0.5px solid rgba(255, 255, 255, 0.07);
        border-radius: 14px;
        padding: 18px;
        position: relative;
        overflow: hidden;
      }
      .review-card::after {
        content: "";
        position: absolute;
        bottom: 0;
        left: 0;
        right: 0;
        height: 60px;
        background: linear-gradient(0deg, rgba(59, 7, 100, 0.15), transparent);
        pointer-events: none;
      }
      .review-stars {
        color: #f59e0b;
        font-size: 13px;
        margin-bottom: 8px;
      }
      .review-text {
        font-size: 13px;
        color: rgba(255, 255, 255, 0.55);
        line-height: 1.6;
        margin-bottom: 14px;
      }
      .review-author {
        display: flex;
        align-items: center;
        gap: 10px;
      }
      .review-avatar {
        width: 30px;
        height: 30px;
        border-radius: 50%;
        background: linear-gradient(135deg, #4f46e5, #7c3aed);
        display: flex;
        align-items: center;
        justify-content: center;
        font-size: 11px;
        font-weight: 500;
        color: #fff;
        flex-shrink: 0;
      }
      .review-name {
        font-size: 13px;
        font-weight: 500;
        color: #fff;
      }
      .review-biz {
        font-size: 12px;
        color: rgba(255, 255, 255, 0.3);
      }

      .rr-pricing {
        padding: 0 40px 60px;
        max-width: 760px;
        margin: 0 auto;
      }
      .pricing-grid {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        gap: 14px;
        margin-top: 32px;
      }
      .price-card {
        background: rgba(255, 255, 255, 0.03);
        border: 0.5px solid rgba(255, 255, 255, 0.08);
        border-radius: 16px;
        padding: 24px;
        position: relative;
        display: flex;
        flex-direction: column;
        text-align: center;
        overflow: hidden;
      }
      .price-card.featured {
        border-color: rgba(139, 92, 246, 0.45);
        background: rgba(139, 92, 246, 0.07);
      }
      .price-card.featured::before {
        content: "";
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        height: 2px;
        background: linear-gradient(90deg, #6366f1, #8b5cf6, #e879f9);
      }
      .price-card.yearly {
        border-color: rgba(236, 72, 153, 0.35);
        background: rgba(236, 72, 153, 0.05);
      }
      .price-card.yearly::before {
        content: "";
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        height: 2px;
        background: linear-gradient(90deg, #8b5cf6, #ec4899, #ef4444);
      }
      .popular-badge {
        display: inline-block;
        background: rgba(139, 92, 246, 0.2);
        border: 0.5px solid rgba(139, 92, 246, 0.4);
        color: #c4b5fd;
        font-size: 10px;
        padding: 3px 10px;
        border-radius: 100px;
        margin-bottom: 10px;
      }
      .save-badge {
        display: inline-block;
        background: rgba(236, 72, 153, 0.15);
        border: 0.5px solid rgba(236, 72, 153, 0.35);
        color: #f9a8d4;
        font-size: 10px;
        padding: 3px 10px;
        border-radius: 100px;
        margin-bottom: 10px;
      }
      .price-plan {
        font-size: 11px;
        color: rgba(255, 255, 255, 0.35);
        margin-bottom: 6px;
        text-transform: uppercase;
        letter-spacing: 1px;
      }
      .price-amount {
        font-size: 32px;
        font-weight: 500;
        color: #fff;
        letter-spacing: -1px;
        line-height: 1;
      }
      .price-amount span {
        font-size: 13px;
        color: rgba(255, 255, 255, 0.35);
        font-weight: 400;
      }
      .price-desc {
        font-size: 12px;
        color: rgba(255, 255, 255, 0.35);
        margin: 8px 0 18px;
        line-height: 1.5;
      }
      .price-features {
        list-style: none;
        margin-bottom: 20px;
        flex: 1;
      }
      .price-features li {
        font-size: 12px;
        color: rgba(255, 255, 255, 0.55);
        padding: 5px 0;
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 7px;
      }
      .price-features li i {
        color: #8b5cf6;
        font-size: 14px;
        flex-shrink: 0;
      }
      .price-features li.pink i {
        color: #ec4899;
      }
      .btn-plan {
        width: 100%;
        padding: 11px;
        border-radius: 9px;
        font-size: 13px;
        font-weight: 500;
        cursor: pointer;
        border: none;
        color: #fff;
        background: linear-gradient(135deg, #f59e0b, #ec4899);
        font-family: "Times New Roman", Times, serif;
      }

      .rr-cta {
        text-align: center;
        padding: 28px 40px 8px;
        position: relative;
        overflow: hidden;
        border-top: 0.5px solid rgba(255, 255, 255, 0.07);
      }
      .rr-cta::before {
        content: "";
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        bottom: 0;
        background: radial-gradient(
          ellipse at center bottom,
          rgba(139, 92, 246, 0.15) 0%,
          rgba(236, 72, 153, 0.08) 40%,
          transparent 70%
        );
        pointer-events: none;
      }
      .rr-cta h2 {
        font-size: 30px;
        font-weight: 500;
        color: #fff;
        margin-bottom: 12px;
        letter-spacing: -0.5px;
        position: relative;
      }
      .rr-cta p {
        font-size: 14px;
        color: rgba(255, 255, 255, 0.4);
        margin-bottom: 28px;
        position: relative;
      }
      .rr-footer {
        text-align: center;
        padding: 4px 20px;
        border-top: 0.5px solid rgba(255, 255, 255, 0.05);
        font-size: 12px;
        color: rgba(255, 255, 255, 0.15);
      }

      .rr-app {
        margin: 0 auto 60px;
        max-width: 680px;
        padding: 0 40px;
        display: none;
      }
      .app-field {
        margin-bottom: 14px;
      }
      .app-field label {
        display: block;
        font-size: 13px;
        font-weight: 500;
        color: rgba(255, 255, 255, 0.6);
        margin-bottom: 8px;
      }
      textarea,
      select {
        width: 100%;
        padding: 12px;
        background: rgba(255, 255, 255, 0.05);
        border: 0.5px solid rgba(255, 255, 255, 0.1);
        border-radius: 10px;
        font-size: 16px;
        color: #fff;
        outline: none;
        resize: vertical;
        font-family: "Times New Roman", Times, serif;
      }
      textarea {
        min-height: 110px;
      }
      textarea:focus,
      select:focus {
        border-color: rgba(139, 92, 246, 0.5);
      }
      select option {
        background: #1e1b4b;
        color: #fff;
      }
      .app-row {
        display: flex;
        gap: 16px;
        margin-bottom: 14px;
      }
      .app-row .app-field {
        flex: 1;
        margin-bottom: 0;
      }
      .stars {
        display: flex;
        gap: 6px;
        font-size: 24px;
        margin-top: 4px;
      }
      .star {
        cursor: pointer;
        color: rgba(255, 255, 255, 0.2);
        transition: 0.2s;
      }
      .star.active {
        color: #fbbf24;
      }
      .btn-generate {
        width: 100%;
        padding: 14px;
        background: linear-gradient(135deg, #8b5cf6, #6366f1);
        color: #fff;
        border: none;
        border-radius: 10px;
        font-size: 15px;
        font-weight: 700;
        cursor: pointer;
        margin-bottom: 16px;
        font-family: "Times New Roman", Times, serif;
      }
      .loading {
        display: none;
        align-items: center;
        justify-content: center;
        gap: 10px;
        color: rgba(255, 255, 255, 0.6);
        margin-bottom: 12px;
        font-size: 14px;
      }
      .loading.active {
        display: flex;
      }
      .loading-spinner {
        width: 16px;
        height: 16px;
        border: 2px solid rgba(139, 92, 246, 0.25);
        border-top-color: #8b5cf6;
        border-radius: 50%;
        animation: spin 0.7s linear infinite;
        flex-shrink: 0;
      }
      @keyframes spin {
        to {
          transform: rotate(360deg);
        }
      }
      .loading-text {
        animation: pulse-text 1.4s ease-in-out infinite;
      }
      @keyframes pulse-text {
        0%,
        100% {
          opacity: 0.5;
        }
        50% {
          opacity: 1;
        }
      }
      .output-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 8px;
      }
      .output-header label {
        font-size: 13px;
        font-weight: 500;
        color: rgba(255, 255, 255, 0.6);
      }
      .copy-btn {
        padding: 6px 16px;
        background: transparent;
        border: 0.5px solid rgba(139, 92, 246, 0.5);
        color: #a78bfa;
        border-radius: 8px;
        font-size: 13px;
        font-weight: 600;
        cursor: pointer;
        font-family: "Times New Roman", Times, serif;
      }
      .output-box {
        background: rgba(139, 92, 246, 0.06);
        border: 0.5px solid rgba(139, 92, 246, 0.2);
        border-radius: 10px;
        padding: 16px;
        min-height: 100px;
        line-height: 1.7;
        white-space: pre-wrap;
        font-size: 16px;
        color: rgba(255, 255, 255, 0.8);
        display: block;
        text-align: left;
      }

      .modal-overlay {
        position: fixed;
        inset: 0;
        background: rgba(0, 0, 0, 0.65);
        display: none;
        align-items: center;
        justify-content: center;
        z-index: 9999;
        padding: 20px;
        box-sizing: border-box;
      }
      .modal-overlay.active {
        display: flex;
      }
      .register-modal {
        width: 420px;
        background: #111827;
        border-radius: 18px;
        padding: 40px;
        position: relative;
        text-align: center;
        box-shadow: 0 20px 60px rgba(0, 0, 0, 0.4);
        border: 0.5px solid rgba(255, 255, 255, 0.1);
        box-sizing: border-box;
      }
      .register-modal h2 {
        color: #fff;
        margin-bottom: 10px;
      }
      .modal-header {
        text-align: center;
        margin-bottom: 20px;
      }
      .modal-subtitle {
        margin-top: 6px;
        font-size: 13px;
        color: #94a3b8;
      }
      .modal-input {
        width: 100%;
        padding: 14px;
        margin-bottom: 16px;
        border-radius: 10px;
        border: 1px solid #334155;
        background: #0f172a;
        color: #fff;
        font-size: 14px;
        font-family: "Times New Roman", Times, serif;
        box-sizing: border-box;
      }
      .modal-register-btn {
        width: 100%;
        padding: 14px 16px;
        border: none;
        border-radius: 10px;
        font-size: 15px;
        font-weight: 600;
        cursor: pointer;
        background: #8b5cf6;
        color: #fff;
        margin-top: 8px;
        font-family: "Times New Roman", Times, serif;
      }
      .switch-auth {
        margin-top: 20px;
        text-align: center;
        color: #94a3b8;
        font-size: 13px;
        line-height: 1.6;
      }
      .switch-auth span {
        display: inline;
        margin-left: 4px;
        font-weight: 600;
        color: #93c5fd;
        cursor: pointer;
        text-decoration: underline;
      }
      .close-modal {
        position: absolute;
        top: 12px;
        right: 12px;
        background: transparent;
        border: none;
        color: #fff;
        font-size: 24px;
        cursor: pointer;
      }
      #successModal {
        position: fixed;
        inset: 0;
        display: none;
        justify-content: center;
        align-items: center;
        background: rgba(0, 0, 0, 0.75);
        z-index: 99999;
      }
      #successModal.active {
        display: flex;
      }
      .success-box {
        background: #1e1b4b;
        border: 0.5px solid rgba(139, 92, 246, 0.4);
        color: #fff;
        padding: 20px 30px;
        border-radius: 12px;
        font-weight: 600;
      }

      @media (max-width: 640px) {
        .rr-nav {
          padding: 10px 14px;
          gap: 8px;
        }
        .nav-left {
          flex-direction: column;
          align-items: center;
          gap: 4px;
        }
        .rr-logo {
          font-size: 20px;
        }
        .lang-switcher {
          padding: 2px;
        }
        .lang-btn {
          padding: 2px 8px;
          font-size: 11px;
        }
        .nav-actions {
          gap: 6px;
          flex-shrink: 0;
        }
        .nav-btn {
          width: 62px;
          height: 30px;
          font-size: 11px;
        }
        .nav-email {
          display: none;
        }
        .nav-plan {
          display: none;
        }
        .rr-hero {
          padding: 50px 20px 40px;
        }
        .rr-hero h1 {
          font-size: 32px;
        }
        .rr-hero p {
          font-size: 14px;
        }
        .rr-hero-btns {
          flex-direction: column;
          align-items: center;
        }
        .rr-demo,
        .rr-app,
        .rr-stats,
        .rr-features,
        .rr-reviews,
        .rr-pricing {
          padding-left: 16px;
          padding-right: 16px;
        }
        .pricing-grid {
          grid-template-columns: 1fr;
        }
        .features-grid {
          grid-template-columns: 1fr;
        }
        .reviews-grid {
          grid-template-columns: 1fr;
        }
        .app-row {
          flex-direction: column;
        }
        .stats-box {
          grid-template-columns: 1fr !important;
          overflow: visible !important;
        }
        .stat-item {
          border-right: none !important;
          border-bottom: 0.5px solid rgba(255, 255, 255, 0.08);
          padding: 20px !important;
        }
        .stat-item:last-child {
          border-bottom: none;
        }
        .demo-inner {
          padding: 18px;
        }
        .modal-overlay {
          padding: 16px;
          align-items: center;
        }
        .register-modal {
          width: 100% !important;
          max-width: 100% !important;
          padding: 32px 20px !important;
          box-sizing: border-box;
        }
      }
    </style>
  </head>
  <body>
    <nav class="rr-nav">
      <div class="nav-left">
        <div class="rr-logo">Review<span>Reply</span></div>
        <div class="lang-switcher">
          <button class="lang-btn active" onclick="setLang('en')">EN</button>
          <button class="lang-btn" onclick="setLang('bg')">BG</button>
        </div>
      </div>
      <div class="nav-actions" id="navActions">
        <button class="nav-btn outline" id="registerBtn">Register</button>
        <button class="nav-btn filled" id="loginBtn">Login</button>
        <button
          class="nav-btn outline"
          id="unsubscribeBtn"
          style="display: none"
          onclick="manageSubscription()"
        >
          Unsubscribe
        </button>
        <button class="nav-btn" id="logoutBtn" style="display: none">
          Logout
        </button>
      </div>
    </nav>

    <p id="authMessage" class="auth-message"></p>

    <section class="rr-hero">
      <div class="hero-glow"></div>
      <div class="rr-badge" id="t-badge">AI-powered review management</div>
      <h1 id="t-h1">
        Reply to reviews in<br /><span class="grad-text"
          >5 seconds with AI</span
        >
      </h1>
      <p id="t-hero-p">
        Stop spending hours writing responses to Google reviews. ReviewReply
        generates professional, personalized replies instantly — so you can
        focus on running your business.
      </p>
      <div class="rr-hero-btns">
        <button class="btn-hero" id="heroTryBtn">Try for free →</button>
        <button class="btn-hero-outline" id="heroSeeBtn">
          See how it works
        </button>
      </div>
    </section>

    <div class="rr-demo" id="demoSection">
      <div class="demo-inner">
        <div class="demo-label" id="t-demo-label">Live demo</div>
        <div class="demo-review">
          <div class="demo-stars">★★★★★</div>
          <span id="t-demo-review"
            >"Great place! Food was amazing and staff very friendly. Will
            definitely come back!"</span
          >
        </div>
        <div class="demo-arrow">↓</div>
        <div class="demo-reply">
          <div class="demo-reply-label" id="t-demo-reply-label">
            AI generated reply
          </div>
          <span id="t-demo-reply"
            >Thank you so much for your kind words — we are thrilled to hear you
            enjoyed the food and had a great experience with our team! We look
            forward to welcoming you back soon.</span
          >
        </div>
      </div>
    </div>

    <div class="rr-app" id="appCard">
      <div class="demo-inner">
        <div class="demo-label" id="t-gen-label">Generate your reply</div>
        <div class="app-field">
          <label id="t-paste-label">📋 Paste a review</label>
          <textarea
            id="reviewInput"
            rows="4"
            placeholder="Example: The room was dirty and staff was rude."
          ></textarea>
        </div>
        <div class="app-row">
          <div class="app-field">
            <label id="t-tone-label">🎨 Reply Tone</label>
            <select id="toneSelect">
              <option value="Professional" id="t-opt1">Professional</option>
              <option value="Friendly" id="t-opt2">Friendly</option>
              <option value="Warm" id="t-opt3">Warm</option>
              <option value="Apologetic" id="t-opt4">Apologetic</option>
            </select>
          </div>
          <div class="app-field">
            <label id="t-rating-label">Review Rating</label>
            <div class="stars" id="stars">
              <span class="star" data-value="1">★</span>
              <span class="star" data-value="2">★</span>
              <span class="star" data-value="3">★</span>
              <span class="star" data-value="4">★</span>
              <span class="star active" data-value="5">★</span>
            </div>
          </div>
        </div>
        <button id="generateBtn" class="btn-generate">
          ✨ Generate Reply for Free
        </button>
        <div class="loading" id="loading">
          <span class="loading-spinner"></span>
          <span class="loading-text">Generating your reply...</span>
        </div>
        <div class="output-header">
          <label id="t-output-label">💬 Generated Reply</label>
          <button class="copy-btn" id="t-copy-btn" onclick="copyReply()">
            Copy
          </button>
        </div>
        <div id="outputBox" class="output-box">
          Your generated reply will appear here...
        </div>
      </div>
    </div>

    <div class="rr-stats">
      <div class="stats-box">
        <div class="stat-item">
          <div class="stat-num">5 sec</div>
          <div class="stat-label" id="t-stat1">Average reply time</div>
        </div>
        <div class="stat-item">
          <div class="stat-num">500+</div>
          <div class="stat-label" id="t-stat2">Businesses using it</div>
        </div>
        <div class="stat-item">
          <div class="stat-num">98%</div>
          <div class="stat-label" id="t-stat3">Satisfaction rate</div>
        </div>
      </div>
    </div>

    <section class="rr-features">
      <div class="section-title" id="t-feat-title">Everything you need</div>
      <div class="section-sub" id="t-feat-sub">
        Designed for any business with Google reviews
      </div>
      <div class="features-grid">
        <div class="feature-card">
          <div class="feature-icon"><i class="ti ti-bolt"></i></div>
          <div class="feature-title" id="t-f1-title">Instant AI replies</div>
          <div class="feature-desc" id="t-f1-desc">
            Generate professional responses in seconds. No more staring at a
            blank screen wondering what to write.
          </div>
        </div>
        <div class="feature-card">
          <div class="feature-icon"><i class="ti ti-adjustments"></i></div>
          <div class="feature-title" id="t-f2-title">Custom tone</div>
          <div class="feature-desc" id="t-f2-desc">
            Choose from friendly, professional, or formal tones to match your
            brand's voice perfectly.
          </div>
        </div>
        <div class="feature-card">
          <div class="feature-icon"><i class="ti ti-star"></i></div>
          <div class="feature-title" id="t-f3-title">Star rating aware</div>
          <div class="feature-desc" id="t-f3-desc">
            The AI adapts its response based on the star rating — different
            approach for 1 star vs 5 stars.
          </div>
        </div>
        <div class="feature-card">
          <div class="feature-icon"><i class="ti ti-device-mobile"></i></div>
          <div class="feature-title" id="t-f4-title">Works on desktop</div>
          <div class="feature-desc" id="t-f4-desc">
            Currently available on desktop. Mobile version coming soon!
          </div>
        </div>
      </div>
    </section>

    <section class="rr-reviews">
      <div class="section-title" id="t-rev-title">Loved by business owners</div>
      <div class="section-sub" id="t-rev-sub">
        Real feedback from real customers
      </div>
      <div class="reviews-grid">
        <div class="review-card">
          <div class="review-stars">★★★★★</div>
          <div class="review-text" id="t-r1">
            "I used to spend 30 minutes a day on review replies. Now it takes 5
            minutes total. This tool is a game changer."
          </div>
          <div class="review-author">
            <div class="review-avatar">MK</div>
            <div>
              <div class="review-name">Maria K.</div>
              <div class="review-biz" id="t-r1-biz">
                Restaurant owner, Sofia
              </div>
            </div>
          </div>
        </div>
        <div class="review-card">
          <div class="review-stars">★★★★★</div>
          <div class="review-text" id="t-r2">
            "The replies sound so natural — my customers cannot tell they are AI
            generated. Absolutely worth the subscription."
          </div>
          <div class="review-author">
            <div class="review-avatar">TP</div>
            <div>
              <div class="review-name">Tom P.</div>
              <div class="review-biz" id="t-r2-biz">Hotel manager, Plovdiv</div>
            </div>
          </div>
        </div>
        <div class="review-card">
          <div class="review-stars">★★★★★</div>
          <div class="review-text" id="t-r3">
            "Perfect for our small team. We manage 3 locations and ReviewReply
            saves us hours every week."
          </div>
          <div class="review-author">
            <div class="review-avatar">SD</div>
            <div>
              <div class="review-name">Stefan D.</div>
              <div class="review-biz" id="t-r3-biz">Retail chain, Varna</div>
            </div>
          </div>
        </div>
        <div class="review-card">
          <div class="review-stars">★★★★★</div>
          <div class="review-text" id="t-r4">
            "Simple, fast, and always professional. My Google rating improved
            since I started responding to every review."
          </div>
          <div class="review-author">
            <div class="review-avatar">AN</div>
            <div>
              <div class="review-name">Ana N.</div>
              <div class="review-biz" id="t-r4-biz">Beauty salon, Burgas</div>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section class="rr-pricing">
      <div class="section-title" id="t-price-title">Simple pricing</div>
      <div class="section-sub" id="t-price-sub">
        Start free, upgrade when you are ready
      </div>
      <div class="pricing-grid">
        <!-- FREE PLAN -->
        <div
          class="price-card"
          style="
            border-color: rgba(132, 204, 22, 0.5);
            background: rgba(132, 204, 22, 0.15);
            overflow: hidden;
          "
        >
          <div
            style="
              position: absolute;
              top: 0;
              left: 0;
              right: 0;
              height: 2px;
              background: linear-gradient(90deg, #65a30d, #bef264);
            "
          ></div>
          <div
            style="
              display: inline-block;
              background: rgba(132, 204, 22, 0.2);
              border: 0.5px solid rgba(132, 204, 22, 0.45);
              color: #d9f99d;
              font-size: 10px;
              padding: 3px 10px;
              border-radius: 100px;
              margin-bottom: 10px;
              position: relative;
              z-index: 1;
            "
            id="t-free-badge"
          >
            No credit card needed
          </div>
          <div
            class="price-plan"
            style="position: relative; z-index: 1"
            id="t-free-plan"
          >
            Free
          </div>
          <div class="price-amount">€0 <span id="t-mo1">/month</span></div>
          <div class="price-desc" id="t-free-desc">
            Perfect for trying it out
          </div>
          <ul class="price-features">
            <li>
              <i class="ti ti-check"></i
              ><span id="t-pf1">6 replies per month</span>
            </li>
            <li>
              <i class="ti ti-check"></i
              ><span id="t-pf2">All tone options</span>
            </li>
            <li>
              <i class="ti ti-check"></i
              ><span id="t-pf3">Copy to clipboard</span>
            </li>
          </ul>
          <button
            class="btn-plan"
            id="t-free-btn"
            onclick="
              document.getElementById('demoSection').style.display = 'none';
              document.getElementById('appCard').style.display = 'block';
              document
                .getElementById('appCard')
                .scrollIntoView({ behavior: 'smooth' });
            "
          >
            Get started free
          </button>
        </div>

        <!-- MONTHLY PLAN -->
        <div class="price-card featured">
          <div class="popular-badge" id="t-pop-badge">Most popular</div>
          <div class="price-plan" id="t-pro-plan">Monthly</div>
          <div class="price-amount">€9.99 <span id="t-mo2">/month</span></div>
          <div class="price-desc" id="t-pro-desc">For businesses</div>
          <ul class="price-features">
            <li>
              <i class="ti ti-check"></i
              ><span id="t-pf4">Unlimited replies</span>
            </li>
            <li>
              <i class="ti ti-check"></i
              ><span id="t-pf5">All tone options</span>
            </li>
            <li>
              <i class="ti ti-check"></i
              ><span id="t-pf6">Priority support</span>
            </li>
            <li>
              <i class="ti ti-check"></i><span id="t-pf7">Cancel anytime</span>
            </li>
          </ul>
          <button
            class="btn-plan"
            onclick="checkout('monthly')"
            id="t-pro-btn"
            style="
              background: linear-gradient(135deg, #6366f1, #8b5cf6);
              border: none;
              color: #fff;
            "
          >
            Месечен - €9.99
          </button>
        </div>

        <!-- YEARLY PLAN -->
        <div class="price-card yearly">
          <div class="save-badge" id="t-save-badge">Save 17%</div>
          <div class="price-plan" id="t-yr-plan">Yearly</div>
          <div class="price-amount">€99 <span id="t-yr1">/year</span></div>
          <div class="price-desc" id="t-yr-desc">
            Best value — 2 months free vs monthly
          </div>
          <ul class="price-features">
            <li class="pink">
              <i class="ti ti-check"></i
              ><span id="t-pf8">Unlimited replies</span>
            </li>
            <li class="pink">
              <i class="ti ti-check"></i
              ><span id="t-pf9">All tone options</span>
            </li>
            <li class="pink">
              <i class="ti ti-check"></i
              ><span id="t-pf10">Priority support</span>
            </li>
            <li class="pink">
              <i class="ti ti-check"></i><span id="t-pf11">Cancel anytime</span>
            </li>
          </ul>
          <button
            class="btn-plan"
            onclick="checkout('yearly')"
            id="t-yr-btn"
            style="
              background: linear-gradient(135deg, #8b5cf6, #ec4899);
              border: none;
              color: #fff;
            "
          >
            Годишен - €99
          </button>
        </div>
      </div>
    </section>

    <section class="rr-cta">
      <h2 id="t-cta-h2">Ready to save hours every week?</h2>
      <p id="t-cta-p">Join hundreds of businesses already using ReviewReply</p>
      <button class="btn-hero" id="ctaTryBtn">Start for free →</button>
      <p
        id="t-footer-support"
        style="margin-top: 28px; margin-bottom: 4px; font-size: 13px"
      ></p>
    </section>

    <footer class="rr-footer">© 2026 ReviewReply. All rights reserved.</footer>

    <!-- REGISTER MODAL -->
    <div class="modal-overlay" id="registerModal">
      <div class="register-modal">
        <button class="close-modal" id="closeModalBtn">×</button>
        <div class="modal-header">
          <h2 id="authTitle">Create Account</h2>
          <p class="modal-subtitle">Start generating smarter review replies.</p>
        </div>
        <div class="modal-body">
          <input
            id="emailInput"
            class="modal-input"
            type="email"
            placeholder="Email"
          />
          <input
            id="passwordInput"
            class="modal-input"
            type="password"
            placeholder="Password (min 6 chars, include a number)"
          />
          <button class="modal-register-btn" id="authSubmitBtn">
            Create Account
          </button>
          <p class="switch-auth" id="switchAuthText">
            Already have an account? <span id="switchAuthMode">Log in</span>
          </p>
        </div>
      </div>
    </div>

    <!-- LOGIN REQUIRED MODAL -->
    <div class="modal-overlay" id="loginRequiredModal">
      <div
        class="register-modal"
        style="
          padding: 40px 24px;
          width: 100%;
          max-width: 380px;
          box-sizing: border-box;
        "
      >
        <button class="close-modal" id="closeLoginRequired">×</button>
        <div class="modal-header" style="margin-bottom: 24px">
          <div
            style="
              width: 48px;
              height: 48px;
              background: rgba(139, 92, 246, 0.15);
              border-radius: 50%;
              display: flex;
              align-items: center;
              justify-content: center;
              margin: 0 auto 16px;
              font-size: 22px;
            "
          >
            🔒
          </div>
          <h2
            id="loginRequiredTitle"
            style="font-size: 18px; color: #fff; line-height: 1.4"
          >
            You've used all 5 free replies!
          </h2>
          <div
            style="
              width: 40px;
              height: 1px;
              background: rgba(139, 92, 246, 0.4);
              margin: 16px auto;
            "
          ></div>
          <p
            class="modal-subtitle"
            id="loginRequiredSubtitle"
            style="
              font-size: 14px;
              color: rgba(255, 255, 255, 0.55);
              font-weight: 400;
              margin-top: 0;
            "
          >
            Subscribe to get more replies.
          </p>
        </div>
        <div class="modal-body">
          <button
            class="modal-register-btn"
            id="goToLoginBtn"
            style="
              padding: 10px 16px;
              font-size: 14px;
              background: linear-gradient(135deg, #8b5cf6, #6366f1);
            "
          >
            Login
          </button>
          <p class="switch-auth" style="margin-top: 24px; font-size: 14px">
            <span style="color: #94a3b8" id="noAccountText"
              >No account yet?</span
            >
            <span
              id="goToRegisterBtn"
              style="
                font-size: 14px;
                font-weight: 700;
                color: #a78bfa;
                cursor: pointer;
                text-decoration: underline;
              "
              >Register</span
            >
          </p>
        </div>
      </div>
    </div>

    <div id="successModal" class="success-modal">
      <div class="success-box">🎉 Registration successful!</div>
    </div>

    <script src="lang.js"></script>
    <script type="module" src="script.js"></script>
    <script>
      document.getElementById("heroTryBtn").onclick = () => {
        document.getElementById("demoSection").style.display = "none";
        document.getElementById("appCard").style.display = "block";
        document
          .getElementById("appCard")
          .scrollIntoView({ behavior: "smooth" });
      };
      document.getElementById("heroSeeBtn").onclick = () => {
        document
          .getElementById("demoSection")
          .scrollIntoView({ behavior: "smooth" });
      };
      document.getElementById("ctaTryBtn").onclick = () => {
        document.getElementById("demoSection").style.display = "none";
        document.getElementById("appCard").style.display = "block";
        document
          .getElementById("appCard")
          .scrollIntoView({ behavior: "smooth" });
      };
    </script>
  </body>
</html>
'@

$scriptJs = @'
/* ===================== */
/* STATE */
/* ===================== */
let rating = 5;
let currentPlan = "monthly";
let currentUser = null;
let userData = null;
let isLoginMode = false;

const FREE_TRIAL_LIMIT = 5;
let anonymousReplyCount = parseInt(
  sessionStorage.getItem("anonReplyCount") || "0",
  10,
);

/* ===================== */
/* FIREBASE IMPORTS */
/* ===================== */
import { initializeApp } from "https://www.gstatic.com/firebasejs/12.13.0/firebase-app.js";
import {
  getAuth,
  createUserWithEmailAndPassword,
  signInWithEmailAndPassword,
  signOut,
  onAuthStateChanged,
  sendEmailVerification,
} from "https://www.gstatic.com/firebasejs/12.13.0/firebase-auth.js";

import {
  getFirestore,
  doc,
  setDoc,
  getDoc,
  updateDoc,
  increment,
} from "https://www.gstatic.com/firebasejs/12.13.0/firebase-firestore.js";

/* ===================== */
/* FIREBASE INIT */
/* ===================== */
const firebaseConfig = {
  apiKey: "AIzaSyDHFzrQkaTZU2sjOxVT1Vympw9QiH-IBKI",
  authDomain: "replypilot-d0ca7.firebaseapp.com",
  projectId: "replypilot-d0ca7",
};

const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db = getFirestore(app);

/* ===================== */
/* AUTH STATE (CRITICAL) */
/* ===================== */
onAuthStateChanged(auth, async (user) => {
  currentUser = user;

  const logoutBtn = document.getElementById("logoutBtn");
  const unsubscribeBtn = document.getElementById("unsubscribeBtn");
  const loginBtn = document.getElementById("loginBtn");
  const registerBtn = document.getElementById("registerBtn");
  let emailDisplay = document.getElementById("navEmailDisplay");

  if (user) {
    logoutBtn.style.display = "inline-block";
    if (loginBtn) loginBtn.style.display = "none";
    if (registerBtn) registerBtn.style.display = "none";

    // Create the email display element if it doesn't exist yet
    if (!emailDisplay) {
      emailDisplay = document.createElement("span");
      emailDisplay.id = "navEmailDisplay";
      emailDisplay.className = "nav-email";
      logoutBtn.parentElement.insertBefore(emailDisplay, logoutBtn);
    }
    emailDisplay.textContent = user.email;
    emailDisplay.style.display = "inline-block";
    emailDisplay.style.marginRight = "10px";

    const ref = doc(db, "users", user.uid);
    const snap = await getDoc(ref);

    if (snap.exists()) userData = snap.data();

    updateUnsubscribeButton();
  } else {
    logoutBtn.style.display = "none";
    if (unsubscribeBtn) unsubscribeBtn.style.display = "none";
    if (loginBtn) loginBtn.style.display = "inline-block";
    if (registerBtn) registerBtn.style.display = "inline-block";
    if (emailDisplay) emailDisplay.style.display = "none";
    userData = null;
  }

  console.log("AUTH STATE:", user?.email || null);
});

/* ===================== */
/* MANAGE / CANCEL SUBSCRIPTION */
/* ===================== */

// Only ever visible/usable for logged-in users with an active
// (or pending-cancellation) premium subscription.
window.updateUnsubscribeButton = function updateUnsubscribeButton() {
  const unsubscribeBtn = document.getElementById("unsubscribeBtn");
  if (!unsubscribeBtn) return;

  if (!currentUser || !userData?.isPremium) {
    unsubscribeBtn.style.display = "none";
    return;
  }

  unsubscribeBtn.style.display = "inline-block";

  if (userData?.cancelAtPeriodEnd) {
    unsubscribeBtn.disabled = true;
    const endDate = userData.currentPeriodEnd
      ? new Date(userData.currentPeriodEnd * 1000).toLocaleDateString(
          window.currentLang === "bg" ? "bg-BG" : "en-US",
        )
      : null;
    unsubscribeBtn.textContent =
      window.currentLang === "bg"
        ? endDate
          ? `Достъп до ${endDate}`
          : "Ще бъде отписан"
        : endDate
          ? `Access until ${endDate}`
          : "Cancels soon";
  } else {
    unsubscribeBtn.disabled = false;
    unsubscribeBtn.textContent =
      window.currentLang === "bg" ? "Отписване" : "Unsubscribe";
  }
}

window.manageSubscription = async function () {
  if (!currentUser || !userData?.isPremium) return;
  if (userData?.cancelAtPeriodEnd) return; // already scheduled

  const confirmMsg =
    window.currentLang === "bg"
      ? "Абонаментът ще бъде отменен и няма да се подновява. Ще запазите достъп до края на текущия платен период. Продължи?"
      : "Your subscription will stop renewing. You'll keep premium access until the end of your current billing period. Continue?";

  if (!window.confirm(confirmMsg)) return;

  const unsubscribeBtn = document.getElementById("unsubscribeBtn");
  if (unsubscribeBtn) unsubscribeBtn.disabled = true;

  try {
    const res = await fetch("/cancel-subscription", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ uid: currentUser.uid }),
    });

    const data = await res.json();

    if (data.canceled) {
      userData.cancelAtPeriodEnd = true;
      userData.currentPeriodEnd = data.currentPeriodEnd;

      const endDate = data.currentPeriodEnd
        ? new Date(data.currentPeriodEnd * 1000).toLocaleDateString(
            window.currentLang === "bg" ? "bg-BG" : "en-US",
          )
        : null;

      showAuthMessage(
        window.currentLang === "bg"
          ? `Отписан си. Ще запазиш достъп${endDate ? ` до ${endDate}` : ""}.`
          : `You're unsubscribed. You'll keep access${endDate ? ` until ${endDate}` : ""}.`,
        "success",
      );

      updateUnsubscribeButton();
    } else if (res.status === 409) {
      // Already scheduled to cancel (e.g. a second click landed before the
      // UI updated, or another tab already canceled it) — just resync local
      // state quietly rather than alarming the user with an "error".
      userData.cancelAtPeriodEnd = true;
      if (data.currentPeriodEnd) userData.currentPeriodEnd = data.currentPeriodEnd;
      updateUnsubscribeButton();
    } else {
      showAuthMessage(
        data.error ||
          (window.currentLang === "bg"
            ? "Неуспешно отписване."
            : "Could not cancel subscription."),
        "error",
      );
      if (unsubscribeBtn) unsubscribeBtn.disabled = false;
    }
  } catch (err) {
    console.error("CANCEL SUBSCRIPTION FAILED:", err);
    showAuthMessage(
      window.currentLang === "bg"
        ? "Неуспешно отписване."
        : "Could not cancel subscription.",
      "error",
    );
    if (unsubscribeBtn) unsubscribeBtn.disabled = false;
  }
};

/* ===================== */
/* MODAL + LOGIN/REGISTER */
/* ===================== */
document.addEventListener("DOMContentLoaded", () => {
  const registerBtn = document.getElementById("registerBtn");
  const loginBtn = document.getElementById("loginBtn");
  const modal = document.getElementById("registerModal");
  const closeBtn = document.getElementById("closeModalBtn");
  const logoutBtn = document.getElementById("logoutBtn");

  const authBtn = document.getElementById("authSubmitBtn");
  const switchMode = document.getElementById("switchAuthMode");
  const title = document.getElementById("authTitle");

  /* OPEN REGISTER */
  function openRegister() {
    isLoginMode = false;
    title.textContent = "Create Account";
    authBtn.textContent = "Create Account";
    modal.classList.add("active");
  }
  registerBtn.onclick = openRegister;

  /* OPEN LOGIN */
  function openLogin() {
    isLoginMode = true;
    title.textContent = "Welcome Back";
    authBtn.textContent = "Login";
    modal.classList.add("active");
  }
  loginBtn.onclick = openLogin;

  closeBtn.onclick = () => modal.classList.remove("active");

  logoutBtn.onclick = () => signOut(auth);

  /* LOGIN REQUIRED MODAL (shown after free trial limit reached) */
  const loginRequiredModal = document.getElementById("loginRequiredModal");
  const closeLoginRequired = document.getElementById("closeLoginRequired");
  const goToLoginBtn = document.getElementById("goToLoginBtn");
  const goToRegisterBtn = document.getElementById("goToRegisterBtn");

  if (closeLoginRequired) {
    closeLoginRequired.onclick = () =>
      loginRequiredModal.classList.remove("active");
  }
  if (goToLoginBtn) {
    goToLoginBtn.onclick = () => {
      loginRequiredModal.classList.remove("active");
      openLogin();
    };
  }
  if (goToRegisterBtn) {
    goToRegisterBtn.onclick = () => {
      loginRequiredModal.classList.remove("active");
      openRegister();
    };
  }

  /* SWITCH TEXT INSIDE MODAL */
  switchMode.onclick = () => {
    isLoginMode = !isLoginMode;

    if (isLoginMode) {
      title.textContent = "Welcome Back";
      authBtn.textContent = "Login";
    } else {
      title.textContent = "Create Account";
      authBtn.textContent = "Create Account";
    }
  };

  /* AUTH ACTION */
  authBtn.onclick = async () => {
    const email = document.getElementById("emailInput").value.trim();
    const password = document.getElementById("passwordInput").value.trim();

    if (!email || !password) {
      showAuthMessage("Please fill in both email and password.", "error");
      return;
    }

    try {
      if (isLoginMode) {
        const cred = await signInWithEmailAndPassword(auth, email, password);

        if (!cred.user.emailVerified) {
          await signOut(auth);
          showAuthMessage(
            "Please verify your email before logging in. Check your inbox for the verification link.",
            "error",
          );
          return;
        }
      } else {
        const cred = await createUserWithEmailAndPassword(
          auth,
          email,
          password,
        );

        await setDoc(doc(db, "users", cred.user.uid), {
          email: cred.user.email,
          isPremium: false,
          usageCount: 0,
        });

        await sendEmailVerification(cred.user);
        await signOut(auth);
        modal.classList.remove("active");
        showAuthMessage(
          "Account created! We've sent a verification link to " +
            cred.user.email +
            " — please verify your email, then log in.",
          "success",
        );
        return;
      }

      modal.classList.remove("active");
    } catch (e) {
      showAuthMessage(getFriendlyAuthError(e), "error");
    }
  };

  /* GENERATE BUTTON */
  document.getElementById("generateBtn").onclick = generateReply;

  /* STAR RATING SELECTOR */
  const starEls = document.querySelectorAll("#stars .star");
  starEls.forEach((starEl) => {
    starEl.addEventListener("click", () => {
      rating = parseInt(starEl.dataset.value, 10);
      starEls.forEach((s) => {
        s.classList.toggle("active", parseInt(s.dataset.value, 10) <= rating);
      });
    });
  });

  /* ENTER KEY SUPPORT IN AUTH MODAL */
  const emailInput = document.getElementById("emailInput");
  const passwordInput = document.getElementById("passwordInput");
  [emailInput, passwordInput].forEach((input) => {
    if (input) {
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          authBtn.click();
        }
      });
    }
  });
});

/* ===================== */
/* ON-PAGE MESSAGE HELPER (replaces alert()) */
/* ===================== */
function showAuthMessage(text, type) {
  const el = document.getElementById("authMessage");
  el.textContent = text;
  el.className = "auth-message show " + (type || "success");
  el.scrollIntoView({ behavior: "smooth", block: "center" });
  clearTimeout(window._authMsgTimeout);
  window._authMsgTimeout = setTimeout(() => {
    el.classList.remove("show");
  }, 8000);
}

function getFriendlyAuthError(error) {
  const code = error?.code || "";
  switch (code) {
    case "auth/invalid-credential":
    case "auth/wrong-password":
    case "auth/user-not-found":
      return "Incorrect email or password. Please try again.";
    case "auth/email-already-in-use":
      return "An account with this email already exists. Try logging in instead.";
    case "auth/invalid-email":
      return "Please enter a valid email address.";
    case "auth/weak-password":
      return "Password is too weak — please use at least 6 characters.";
    case "auth/too-many-requests":
      return "Too many attempts. Please wait a moment and try again.";
    default:
      return "Something went wrong. Please try again.";
  }
}

/* ===================== */
/* REPLY GENERATOR (FIXED SAFE) */
/* ===================== */
const REGISTERED_FREE_LIMIT = 3;
const EXEMPT_TEST_EMAILS = ["dimitardamianov@yahoo.com"];

async function generateReply() {
  const review = document.getElementById("reviewInput").value;
  const output = document.getElementById("outputBox");
  const loading = document.getElementById("loading");

  if (!review) return alert("Add review");

  const isExemptTestAccount =
    currentUser && EXEMPT_TEST_EMAILS.includes(currentUser.email);

  /* TIER 1: anonymous visitor, not logged in */
  if (!currentUser) {
    if (anonymousReplyCount >= FREE_TRIAL_LIMIT) {
      const loginRequiredModal = document.getElementById("loginRequiredModal");
      if (loginRequiredModal) loginRequiredModal.classList.add("active");
      return;
    }
  } else if (!isExemptTestAccount) {
    /* TIER 2: logged in, not premium yet — 3 more free replies */
    if (!userData?.isPremium) {
      const used = userData?.usageCount || 0;
      if (used >= REGISTERED_FREE_LIMIT) {
        showAuthMessage(
          "You've used all your free replies as a registered user. Please subscribe to continue generating replies.",
          "error",
        );
        return;
      }
    }
  }

  loading.classList.add("active");

  const res = await fetch("/api/reply", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      review,
      rating,
      tone: "Friendly",
      uid: currentUser ? currentUser.uid : undefined,
    }),
  });

  loading.classList.remove("active");

  if (res.status === 403) {
    const errData = await res.json().catch(() => ({}));
    if (errData.error === "FREE_LIMIT_REACHED") {
      const loginRequiredModal = document.getElementById("loginRequiredModal");
      if (loginRequiredModal) loginRequiredModal.classList.add("active");
      return;
    }
  }

  const data = await res.json();

  output.textContent = data.reply || "No response";

  if (!currentUser) {
    anonymousReplyCount += 1;
    sessionStorage.setItem("anonReplyCount", String(anonymousReplyCount));

    const remaining = FREE_TRIAL_LIMIT - anonymousReplyCount;
    if (remaining > 0) {
      showAuthMessage(
        `You have ${remaining} free ${remaining === 1 ? "try" : "tries"} left. Register to keep using ReviewReply after that.`,
        "success",
      );
    }
  } else if (!userData?.isPremium) {
    const ref = doc(db, "users", currentUser.uid);

    if (isExemptTestAccount) {
      // Show the same messages a normal user would see, but loop
      // the count back to 0 once it would hit the limit, so this
      // test account is never actually blocked.
      const wouldBeUsed = (userData.usageCount || 0) + 1;
      if (wouldBeUsed >= REGISTERED_FREE_LIMIT) {
        userData.usageCount = 0;
        showAuthMessage(
          "You've used all your free replies as a registered user. Please subscribe to continue generating replies. (Test account — limit auto-reset.)",
          "error",
        );
        updateDoc(ref, { usageCount: 0 }).catch((err) =>
          console.error("Failed to reset usageCount:", err),
        );
      } else {
        userData.usageCount = wouldBeUsed;
        const remaining = REGISTERED_FREE_LIMIT - wouldBeUsed;
        showAuthMessage(
          `You have ${remaining} free ${remaining === 1 ? "reply" : "replies"} left before you'll need to subscribe. (Test account)`,
          "success",
        );
        updateDoc(ref, { usageCount: increment(1) }).catch((err) =>
          console.error("Failed to update usageCount:", err),
        );
      }
    } else {
      userData.usageCount = (userData.usageCount || 0) + 1;
      const remaining = REGISTERED_FREE_LIMIT - userData.usageCount;
      if (remaining > 0) {
        showAuthMessage(
          `You have ${remaining} free ${remaining === 1 ? "reply" : "replies"} left before you'll need to subscribe.`,
          "success",
        );
      }
      updateDoc(ref, { usageCount: increment(1) }).catch((err) =>
        console.error("Failed to update usageCount:", err),
      );
    }
  }
}

/* ===================== */
/* COPY REPLY BUTTON */
/* ===================== */
window.copyReply = function () {
  const outputBox = document.getElementById("outputBox");
  if (!outputBox) return;
  navigator.clipboard
    .writeText(outputBox.textContent)
    .then(() => showAuthMessage("Copied to clipboard!", "success"))
    .catch(() => showAuthMessage("Could not copy text.", "error"));
};

/* ===================== */
/* PRICING FIX */
/* ===================== */
window.selectPlan = function (plan) {
  currentPlan = plan;

  document
    .querySelectorAll(".pricing-card")
    .forEach((c) => c.classList.remove("popular"));

  document.querySelector(`.pricing-card.${plan}`)?.classList.add("popular");
};

window.checkout = async function (plan) {
  if (!currentUser) return alert("Login first");

  const res = await fetch("/create-checkout-session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      plan,
      uid: currentUser.uid,
      email: currentUser.email,
    }),
  });

  const data = await res.json();
  if (data.url) window.location.href = data.url;
};

/* ===================== */
/* SUPPORT EMAIL LINK (built via JS so it can't be broken by HTML formatting) */
/* ===================== */
document.addEventListener("DOMContentLoaded", () => {
  const supportEl = document.getElementById("t-footer-support");
  if (supportEl) {
    const lang = window.currentLang || "en";
    const text =
      lang === "bg"
        ? "При проблеми пишете на Клиентска поддръжка на "
        : "Any problems write to Customer support at ";

    supportEl.style.background = "linear-gradient(135deg, #f59e0b, #ec4899)";
    supportEl.style.webkitBackgroundClip = "text";
    supportEl.style.backgroundClip = "text";
    supportEl.style.webkitTextFillColor = "transparent";
    supportEl.style.display = "block";

    const leadSpan = document.createElement("span");
    leadSpan.textContent = text;

    const link = document.createElement("a");
    link.href = "mailto:bestdealsbg2026@gmail.com";
    link.textContent = "bestdealsbg2026@gmail.com";
    link.style.textDecoration = "underline";
    link.style.fontWeight = "500";
    link.style.color = "inherit";

    supportEl.textContent = "";
    supportEl.appendChild(leadSpan);
    supportEl.appendChild(link);
  }
});
'@

$langJs = @'
const translations = {
  en: {
    badge: "AI-powered review management",
    h1: 'Reply to reviews in<br><span class="grad-text">5 seconds with AI</span>',
    heroP:
      "Stop spending hours writing responses to Google reviews. ReviewReply generates professional, personalized replies instantly so you can focus on running your business.",
    heroTryBtn: "Try for free →",
    heroSeeBtn: "See how it works",
    demoLabel: "Live demo",
    demoReview:
      "Great place! Food was amazing and staff very friendly. Will definitely come back!",
    demoReplyLabel: "AI generated reply",
    demoReply:
      "Thank you so much for your kind words. We are thrilled to hear you enjoyed the food and had a great experience with our team! We look forward to welcoming you back soon.",
    genLabel: "Generate your reply",
    pasteLabel: "📋 Paste a review",
    textareaPh: "Example: The room was dirty and staff was rude.",
    toneLabel: "🎨 Reply Tone",
    opt1: "Professional",
    opt2: "Friendly",
    opt3: "Warm",
    opt4: "Apologetic",
    ratingLabel: "Review Rating",
    generateBtn: "✨ Generate Reply for Free",
    loading: "Generating your reply...",
    outputLabel: "💬 Generated Reply",
    copyBtn: "Copy",
    outputBox: "Your generated reply will appear here...",
    stat1: "Average reply time",
    stat2: "Businesses using it",
    stat3: "Satisfaction rate",
    featTitle: "Everything you need",
    featSub: "Designed for any business with Google reviews",
    f1Title: "Instant AI replies",
    f1Desc:
      "Generate professional responses in seconds. No more staring at a blank screen wondering what to write.",
    f2Title: "Custom tone",
    f2Desc:
      "Choose from friendly, professional, or formal tones to match your brand voice perfectly.",
    f3Title: "Star rating aware",
    f3Desc:
      "The AI adapts its response based on the star rating - different approach for 1 star vs 5 stars.",
    f4Title: "Works everywhere",
    f4Desc: "Currently available on desktop. Mobile version coming soon!",
    revTitle: "Loved by business owners",
    revSub: "Real feedback from real customers",
    r1: "I used to spend 30 minutes a day on review replies. Now it takes 5 minutes total. This tool is a game changer.",
    r1Biz: "Restaurant owner, Sofia",
    r2: "The replies sound so natural - my customers cannot tell they are AI generated. Absolutely worth the subscription.",
    r2Biz: "Hotel manager, Plovdiv",
    r3: "Perfect for our small team. We manage 3 locations and ReviewReply saves us hours every week.",
    r3Biz: "Retail chain, Varna",
    r4: "Simple, fast, and always professional. My Google rating improved since I started responding to every review.",
    r4Biz: "Beauty salon, Burgas",
    priceTitle: "Simple pricing",
    priceSub: "Start free, upgrade when you are ready",
    freeBadge: "No credit card needed",
    freePlan: "Free",
    mo1: "/month",
    freeDesc: "Perfect for trying it out",
    pf1: "6 replies per month",
    pf2: "All tone options",
    pf3: "Copy to clipboard",
    freeBtn: "Get started free",
    popBadge: "Most popular",
    proPlan: "Monthly",
    mo2: "/month",
    proDesc: "For businesses",
    pf4: "Unlimited replies",
    pf5: "All tone options",
    pf6: "Priority support",
    pf7: "Cancel anytime",
    proBtn: "Monthly - €9.99",
    saveBadge: "Save 17%",
    yrPlan: "Yearly",
    yr1: "/year",
    yrDesc: "Best value - 2 months free vs monthly",
    pf8: "Unlimited replies",
    pf9: "All tone options",
    pf10: "Priority support",
    pf11: "Cancel anytime",
    yrBtn: "Yearly - €99",
    ctaH2: "Ready to save hours every week?",
    ctaP: "Join hundreds of businesses already using ReviewReply",
    ctaTryBtn: "Start for free →",
    footerSupport:
      'Any problems write to Customer support at <a href="mailto:bestdealsbg2026@gmail.com" style="color: rgba(255,255,255,0.35); text-decoration: underline;">bestdealsbg2026@gmail.com</a>',
  },
  bg: {
    badge: "AI управление на ревюта",
    h1: 'Отговаряй на ревюта за<br><span class="grad-text">5 секунди с AI</span>',
    heroP:
      "Спри да губиш часове в писане на отговори на Google ревюта. ReviewReply генерира професионални отговори мигновено.",
    heroTryBtn: "Пробвай безплатно →",
    heroSeeBtn: "Виж как работи",
    demoLabel: "Демо",
    demoReview:
      "Страхотно място! Храната беше невероятна и персоналът много приятелски. Определено ще се върна!",
    demoReplyLabel: "AI генериран отговор",
    demoReply:
      "Благодарим ви от сърце за добрите думи! Очакваме да ви посрещнем отново.",
    genLabel: "Генерирай отговор",
    pasteLabel: "📋 Постави ревю",
    textareaPh: "Пример: Стаята беше мръсна и персоналът груб.",
    toneLabel: "🎨 Тон на отговора",
    opt1: "Професионален",
    opt2: "Приятелски",
    opt3: "Топъл",
    opt4: "Извинителен",
    ratingLabel: "Оценка на ревюто",
    generateBtn: "✨ Генерирай безплатно",
    loading: "Генерирам отговор...",
    outputLabel: "💬 Генериран отговор",
    copyBtn: "Копирай",
    outputBox: "Вашият генериран отговор ще се появи тук...",
    stat1: "Средно време за отговор",
    stat2: "Бизнеси, използващи го",
    stat3: "Степен на удовлетвореност",
    featTitle: "Всичко което ти трябва",
    featSub: "Създадено за всеки бизнес с Google ревюта",
    f1Title: "Мигновени AI отговори",
    f1Desc: "Генерирай професионални отговори за секунди.",
    f2Title: "Персонализиран тон",
    f2Desc: "Избери от приятелски, професионален или формален тон.",
    f3Title: "Отчита звездната оценка",
    f3Desc: "AI адаптира отговора спрямо оценката.",
    f4Title: "Работи навсякъде",
    f4Desc: "В момента достъпно на компютър. Мобилната версия идва скоро!",
    revTitle: "Обичано от собственици на бизнеси",
    revSub: "Истинска обратна връзка от истински клиенти",
    r1: "Прекарвах 30 минути на ден в отговори. Сега отнема 5 минути общо. Този инструмент промени всичко.",
    r1Biz: "Собственик на ресторант, София",
    r2: "Отговорите звучат толкова естествено. Абсолютно си заслужава абонамента.",
    r2Biz: "Мениджър на хотел, Пловдив",
    r3: "Перфектно за малкия ни екип. Управляваме 3 локации и ReviewReply ни спестява часове.",
    r3Biz: "Търговска верига, Варна",
    r4: "Просто, бързо и винаги професионално. Google рейтингът ми се подобри.",
    r4Biz: "Салон за красота, Бургас",
    priceTitle: "Прости цени",
    priceSub: "Започни безплатно, надгради когато си готов",
    freeBadge: "Без кредитна карта",
    freePlan: "Безплатен",
    mo1: "/месец",
    freeDesc: "Перфектно за пробване",
    pf1: "6 отговора на месец",
    pf2: "Всички тонове",
    pf3: "Копиране",
    freeBtn: "Започни безплатно",
    popBadge: "Най-популярен",
    proPlan: "Месечен",
    mo2: "/месец",
    proDesc: "За бизнеси",
    pf4: "Неограничени отговори",
    pf5: "Всички тонове",
    pf6: "Приоритетна поддръжка",
    pf7: "Откажи по всяко време",
    proBtn: "Месечен - €9.99",
    saveBadge: "Спести 17%",
    yrPlan: "Годишен",
    yr1: "/година",
    yrDesc: "Най-добра стойност",
    pf8: "Неограничени отговори",
    pf9: "Всички тонове",
    pf10: "Приоритетна поддръжка",
    pf11: "Откажи по всяко време",
    yrBtn: "Годишен - €99",
    ctaH2: "Готов ли си да спестяваш часове всяка седмица?",
    ctaP: "Присъедини се към стотиците бизнеси, използващи ReviewReply",
    ctaTryBtn: "Започни безплатно →",
    footerSupport:
      'При проблеми пишете на Клиентска поддръжка на <a href="mailto:bestdealsbg2026@gmail.com" style="color: rgba(255,255,255,0.35); text-decoration: underline;">bestdealsbg2026@gmail.com</a>',
  },
};

const elMap = {
  badge: "t-badge",
  h1: "t-h1",
  heroP: "t-hero-p",
  heroTryBtn: "heroTryBtn",
  heroSeeBtn: "heroSeeBtn",
  demoLabel: "t-demo-label",
  demoReview: "t-demo-review",
  demoReplyLabel: "t-demo-reply-label",
  demoReply: "t-demo-reply",
  genLabel: "t-gen-label",
  pasteLabel: "t-paste-label",
  toneLabel: "t-tone-label",
  opt1: "t-opt1",
  opt2: "t-opt2",
  opt3: "t-opt3",
  opt4: "t-opt4",
  ratingLabel: "t-rating-label",
  generateBtn: "generateBtn",
  loading: "loading",
  outputLabel: "t-output-label",
  copyBtn: "t-copy-btn",
  stat1: "t-stat1",
  stat2: "t-stat2",
  stat3: "t-stat3",
  featTitle: "t-feat-title",
  featSub: "t-feat-sub",
  f1Title: "t-f1-title",
  f1Desc: "t-f1-desc",
  f2Title: "t-f2-title",
  f2Desc: "t-f2-desc",
  f3Title: "t-f3-title",
  f3Desc: "t-f3-desc",
  f4Title: "t-f4-title",
  f4Desc: "t-f4-desc",
  revTitle: "t-rev-title",
  revSub: "t-rev-sub",
  r1: "t-r1",
  r1Biz: "t-r1-biz",
  r2: "t-r2",
  r2Biz: "t-r2-biz",
  r3: "t-r3",
  r3Biz: "t-r3-biz",
  r4: "t-r4",
  r4Biz: "t-r4-biz",
  priceTitle: "t-price-title",
  priceSub: "t-price-sub",
  freeBadge: "t-free-badge",
  freePlan: "t-free-plan",
  mo1: "t-mo1",
  freeDesc: "t-free-desc",
  pf1: "t-pf1",
  pf2: "t-pf2",
  pf3: "t-pf3",
  freeBtn: "t-free-btn",
  popBadge: "t-pop-badge",
  proPlan: "t-pro-plan",
  mo2: "t-mo2",
  proDesc: "t-pro-desc",
  pf4: "t-pf4",
  pf5: "t-pf5",
  pf6: "t-pf6",
  pf7: "t-pf7",
  proBtn: "t-pro-btn",
  saveBadge: "t-save-badge",
  yrPlan: "t-yr-plan",
  yr1: "t-yr1",
  yrDesc: "t-yr-desc",
  pf8: "t-pf8",
  pf9: "t-pf9",
  pf10: "t-pf10",
  pf11: "t-pf11",
  yrBtn: "t-yr-btn",
  ctaH2: "t-cta-h2",
  ctaP: "t-cta-p",
  ctaTryBtn: "ctaTryBtn",
  footerSupport: "t-footer-support",
};

function setLang(lang) {
  window.currentLang = lang;
  document
    .querySelectorAll(".lang-btn")
    .forEach((b) => b.classList.remove("active"));
  document
    .querySelector(".lang-btn[onclick=\"setLang('" + lang + "')\"]")
    .classList.add("active");
  const t = translations[lang];
  for (const [key, elId] of Object.entries(elMap)) {
    const el = document.getElementById(elId);
    if (el && t[key] !== undefined) el.innerHTML = t[key];
  }
  const ta = document.getElementById("reviewInput");
  if (ta) ta.placeholder = t.textareaPh;
  const ob = document.getElementById("outputBox");
  if (ob && ob.textContent.trim().length < 60) ob.textContent = t.outputBox;

  // Update navbar buttons if not logged in
  const loginBtn = document.getElementById("loginBtn");
  const registerBtn = document.getElementById("registerBtn");
  if (loginBtn) loginBtn.textContent = lang === "bg" ? "Вход" : "Login";
  if (registerBtn)
    registerBtn.textContent = lang === "bg" ? "Регистрация" : "Register";

  if (typeof window.updateUnsubscribeButton === "function") {
    window.updateUnsubscribeButton();
  }

  // Translate register modal
  const modalSubtitle = document.querySelector(
    "#registerModal .modal-subtitle",
  );
  const emailInput = document.getElementById("emailInput");
  const passwordInput = document.getElementById("passwordInput");
  if (lang === "bg") {
    if (modalSubtitle)
      modalSubtitle.textContent = "Генерирай по-умни отговори на ревюта.";
    if (emailInput) emailInput.placeholder = "Имейл";
    if (passwordInput)
      passwordInput.placeholder = "Парола (мин. 6 знака, включи число)";
  } else {
    if (modalSubtitle)
      modalSubtitle.textContent = "Start generating smarter review replies.";
    if (emailInput) emailInput.placeholder = "Email";
    if (passwordInput)
      passwordInput.placeholder = "Password (min 6 chars, include a number)";
  }

  // Translate login required modal
  if (lang === "bg") {
    const h2 = document.querySelector("#loginRequiredModal h2");
    const p = document.querySelector("#loginRequiredModal .modal-subtitle");
    const goLoginBtn = document.getElementById("goToLoginBtn");
    const regBtn = document.getElementById("goToRegisterBtn");
    if (h2) h2.textContent = "Необходима е регистрация";
    if (p) p.textContent = "Влез или създай акаунт за да генерираш отговори.";
    if (goLoginBtn) goLoginBtn.textContent = "Вход";
    if (regBtn) regBtn.textContent = "Регистрация";
  } else {
    const h2 = document.querySelector("#loginRequiredModal h2");
    const p = document.querySelector("#loginRequiredModal .modal-subtitle");
    const goLoginBtn = document.getElementById("goToLoginBtn");
    const regBtn = document.getElementById("goToRegisterBtn");
    if (h2) h2.textContent = "Login Required";
    if (p)
      p.textContent = "Please log in or create an account to generate replies.";
    if (goLoginBtn) goLoginBtn.textContent = "Login";
    if (regBtn) regBtn.textContent = "Register";
  }
}
'@

Set-Content -Path ".\server.js" -Value $serverJs -NoNewline
Set-Content -Path ".\index.html" -Value $indexHtml -NoNewline
Set-Content -Path ".\script.js" -Value $scriptJs -NoNewline
New-Item -ItemType Directory -Force -Path ".\public" | Out-Null
Set-Content -Path ".\public\index.html" -Value $indexHtml -NoNewline
Set-Content -Path ".\public\script.js" -Value $scriptJs -NoNewline
Set-Content -Path ".\public\lang.js" -Value $langJs -NoNewline

Write-Host "Files written. Checking for unsubscribeBtn in script.js:"
Select-String -Path ".\script.js" -Pattern "unsubscribeBtn"

git add server.js index.html script.js public/index.html public/script.js public/lang.js
git commit -m "Add unsubscribe button: cancel Stripe subscription at period end"
git push origin main