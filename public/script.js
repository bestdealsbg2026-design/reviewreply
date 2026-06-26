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
      showAuthMessage(e.message, "error");
    }
  };

  /* GENERATE BUTTON */
  document.getElementById("generateBtn").onclick = generateReply;

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

/* ===================== */
/* REPLY GENERATOR (FIXED SAFE) */
/* ===================== */
const REGISTERED_FREE_LIMIT = 3;

async function generateReply() {
  const review = document.getElementById("reviewInput").value;
  const output = document.getElementById("outputBox");
  const loading = document.getElementById("loading");

  if (!review) return alert("Add review");

  /* TIER 1: anonymous visitor, not logged in */
  if (!currentUser) {
    if (anonymousReplyCount >= FREE_TRIAL_LIMIT) {
      const loginRequiredModal = document.getElementById("loginRequiredModal");
      if (loginRequiredModal) loginRequiredModal.classList.add("active");
      return;
    }
  } else {
    /* TIER 2: logged in, not premium yet — 3 more free replies */
    if (!userData?.isPremium) {
      const used = userData?.usageCount || 0;
      if (used >= REGISTERED_FREE_LIMIT) {
        showAuthMessage(
          "You've used all your free replies as a registered user. Please subscribe to continue generating replies.",
          "error",
        );
        document
          .querySelector(".rr-pricing")
          ?.scrollIntoView({ behavior: "smooth" });
        return;
      }
    }
  }

  loading.style.display = "block";

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

  loading.style.display = "none";

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
    await updateDoc(ref, { usageCount: increment(1) });
    userData.usageCount = (userData.usageCount || 0) + 1;

    const remaining = REGISTERED_FREE_LIMIT - userData.usageCount;
    if (remaining > 0) {
      showAuthMessage(
        `You have ${remaining} free ${remaining === 1 ? "reply" : "replies"} left before you'll need to subscribe.`,
        "success",
      );
    }
  }
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
