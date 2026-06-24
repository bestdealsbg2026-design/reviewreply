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
   AI REPLY
========================= */
app.post("/api/reply", async (req, res) => {
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
