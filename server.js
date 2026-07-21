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

/* =========================
   EMAIL NOTIFICATIONS
   Uses Resend's HTTPS API (https://resend.com) instead of SMTP —
   Railway blocks outbound SMTP ports (465/587) on Free/Trial/Hobby
   plans, so a regular Gmail SMTP connection just hangs forever there.
   Resend works over plain HTTPS, so it isn't affected by that block.
   Requires RESEND_API_KEY and RESEND_FROM_EMAIL env vars.
   Failures here are logged but never block the actual cancellation.
========================= */
const NOTIFY_EMAILS = ["bestdealsbg2026@gmail.com"];

const resendConfigured = !!process.env.RESEND_API_KEY;
if (!resendConfigured) {
  console.warn(
    "RESEND_API_KEY not set — unsubscribe email notifications are disabled.",
  );
}

async function notifyUnsubscribe({ userEmail, uid, currentPeriodEnd }) {
  if (!resendConfigured) return { sent: false, reason: "not configured" };

  const periodEndText = currentPeriodEnd
    ? new Date(currentPeriodEnd * 1000).toLocaleDateString("en-US")
    : "unknown";

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${process.env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from:
          process.env.RESEND_FROM_EMAIL || "ReviewReply <onboarding@resend.dev>",
        to: NOTIFY_EMAILS,
        subject: "ReviewReply — a user unsubscribed",
        text: `A user has canceled their subscription.

User email: ${userEmail || "unknown"}
User ID: ${uid}
Access remains active until: ${periodEndText}
`,
      }),
    });

    const data = await res.json().catch(() => ({}));

    if (!res.ok) {
      console.error("UNSUBSCRIBE EMAIL NOTIFICATION FAILED:", data);
      return { sent: false, error: data?.message || `HTTP ${res.status}` };
    }

    return { sent: true, id: data?.id };
  } catch (err) {
    console.error("UNSUBSCRIBE EMAIL NOTIFICATION FAILED:", err);
    return { sent: false, error: err.message };
  }
}

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

    // Fire-and-forget — don't delay the response to the user on email sending.
    notifyUnsubscribe({
      userEmail: userDoc.data().email,
      uid,
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
