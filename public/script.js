/* ===================== */
/* STATE */
/* ===================== */
let rating = 5;
let currentPlan = "monthly";
let currentUser = null;
let userData = null;
let isLoginMode = false;

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
  } else {
    logoutBtn.style.display = "none";
    if (loginBtn) loginBtn.style.display = "inline-block";
    if (registerBtn) registerBtn.style.display = "inline-block";
    if (emailDisplay) emailDisplay.style.display = "none";
    userData = null;
  }

  console.log("AUTH STATE:", user?.email || null);
});

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
  registerBtn.onclick = () => {
    isLoginMode = false;
    title.textContent = "Create Account";
    authBtn.textContent = "Create Account";
    modal.classList.add("active");
  };

  /* OPEN LOGIN */
  loginBtn.onclick = () => {
    isLoginMode = true;
    title.textContent = "Welcome Back";
    authBtn.textContent = "Login";
    modal.classList.add("active");
  };

  closeBtn.onclick = () => modal.classList.remove("active");

  logoutBtn.onclick = () => signOut(auth);

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

    if (!email || !password) return alert("Missing fields");

    try {
      if (isLoginMode) {
        const cred = await signInWithEmailAndPassword(auth, email, password);

        if (!cred.user.emailVerified) {
          await signOut(auth);
          alert(
            "Please verify your email before logging in. Check your inbox for the verification link, or click 'Resend' below.",
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
        alert(
          "Account created! We've sent a verification link to " +
            cred.user.email +
            " — please verify your email, then log in.",
        );
      }

      modal.classList.remove("active");
    } catch (e) {
      alert(e.message);
    }
  };

  /* GENERATE BUTTON */
  document.getElementById("generateBtn").onclick = generateReply;
});

/* ===================== */
/* REPLY GENERATOR (FIXED SAFE) */
/* ===================== */
async function generateReply() {
  if (!currentUser) return alert("Login first");
  if (!userData) return alert("User not loaded");

  const review = document.getElementById("reviewInput").value;
  const output = document.getElementById("outputBox");
  const loading = document.getElementById("loading");

  if (!review) return alert("Add review");

  loading.style.display = "block";

  const res = await fetch("/api/reply", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ review, rating, tone: "Friendly" }),
  });

  const data = await res.json();

  output.textContent = data.reply || "No response";

  loading.style.display = "none";
}

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
    const link = document.createElement("a");
    link.href = "mailto:bestdealsbg2026@gmail.com";
    link.textContent = "bestdealsbg2026@gmail.com";
    link.style.color = "rgba(255,255,255,0.45)";
    link.style.textDecoration = "underline";
    supportEl.textContent = text;
    supportEl.appendChild(link);
  }
});
