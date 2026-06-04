/* ===================== */
/* STATE */
/* ===================== */
let rating = 5;
let currentPlan = "monthly";
let currentUser = null;
let userData = null;
let isLoginMode = false;

const FREE_LIMIT = 6;

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
/* GUEST USAGE TRACKING */
/* ===================== */
function getGuestCount() {
  return parseInt(localStorage.getItem("guestCount") || "0");
}

function incrementGuestCount() {
  const count = getGuestCount() + 1;
  localStorage.setItem("guestCount", count);
  return count;
}

function updateGuestCounter() {
  const remaining = FREE_LIMIT - getGuestCount();
  const btn = document.getElementById("generateBtn");
  if (btn && !currentUser) {
    btn.textContent =
      remaining > 0
        ? `✨ Generate Reply for Free (${remaining} left)`
        : "✨ Register to continue";
  }
}

/* ===================== */
/* NAVBAR RENDERER */
/* ===================== */
function renderNavbar(user, data = null) {
  const nav = document.getElementById("navActions");

  if (user) {
    const planLabel = data?.isPremium
      ? '<span class="nav-plan premium">⭐ Premium</span>'
      : '<span class="nav-plan free">Free Plan</span>';

    nav.innerHTML = `
      <span class="nav-email">${user.email}</span>
      ${planLabel}
      <button class="nav-btn outline" id="logoutBtn">Logout</button>
    `;
    document.getElementById("logoutBtn").onclick = () => signOut(auth);
  } else {
    nav.innerHTML = `
      <button class="nav-btn outline" id="loginBtn">Login</button>
      <button class="nav-btn filled" id="registerBtn">Register</button>
    `;
    document.getElementById("loginBtn").onclick = () => openModal(true);
    document.getElementById("registerBtn").onclick = () => openModal(false);
    updateGuestCounter();
  }
}

/* ===================== */
/* AUTH STATE */
/* ===================== */
onAuthStateChanged(auth, async (user) => {
  currentUser = user;

  if (user) {
    const ref = doc(db, "users", user.uid);
    const snap = await getDoc(ref);
    if (snap.exists()) {
      userData = snap.data();
    }
    renderNavbar(user, userData);
    // Reset generate button text for logged in users
    const btn = document.getElementById("generateBtn");
    if (btn) btn.textContent = "✨ Generate Reply for Free";
  } else {
    userData = null;
    renderNavbar(null);
  }

  console.log("AUTH STATE:", user?.email || null);
});

/* ===================== */
/* MODAL HELPERS */
/* ===================== */
function openModal(loginMode) {
  isLoginMode = loginMode;
  updateModalUI();
  document.getElementById("registerModal").classList.add("active");
}

function updateModalUI() {
  const title = document.getElementById("authTitle");
  const authBtn = document.getElementById("authSubmitBtn");
  const switchText = document.getElementById("switchAuthText");
  const switchLink = document.getElementById("switchAuthMode");

  if (isLoginMode) {
    title.textContent = "Welcome Back";
    authBtn.textContent = "Login";
    switchText.childNodes[0].textContent = "Don't have an account? ";
    switchLink.textContent = "Register";
  } else {
    title.textContent = "Create Account";
    authBtn.textContent = "Create Account";
    switchText.childNodes[0].textContent = "Already have an account? ";
    switchLink.textContent = "Log in";
  }
}

/* ===================== */
/* DOM READY */
/* ===================== */
document.addEventListener("DOMContentLoaded", () => {
  const modal = document.getElementById("registerModal");
  const closeBtn = document.getElementById("closeModalBtn");
  const authBtn = document.getElementById("authSubmitBtn");
  const switchLink = document.getElementById("switchAuthMode");

  closeBtn.onclick = () => modal.classList.remove("active");

  document.getElementById("registerModal").addEventListener("keydown", (e) => {
    if (e.key === "Enter") authBtn.click();
  });

  switchLink.onclick = () => {
    isLoginMode = !isLoginMode;
    updateModalUI();
  };

  authBtn.onclick = async () => {
    const email = document.getElementById("emailInput").value.trim();
    const password = document.getElementById("passwordInput").value.trim();

    if (!email || !password)
      return showModalError("Please fill in all fields.");

    if (!isLoginMode) {
      if (password.length < 6 || !/\d/.test(password)) {
        return showModalError(
          "Password must be at least 6 characters and contain a number.",
        );
      }
    }

    try {
      if (isLoginMode) {
        const cred = await signInWithEmailAndPassword(auth, email, password);
        if (!cred.user.emailVerified) {
          await signOut(auth);
          return showModalError(
            "Please verify your email first. Check your inbox!",
          );
        }
        showSuccessMessage("👋 Welcome back! You're logged in.");
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
          stripeCustomerId: null,
          lastReset: new Date().toISOString(),
        });
        await sendEmailVerification(cred.user);
        await signOut(auth);
        showSuccessMessage("📧 Check your email to verify your account!");
      }

      modal.classList.remove("active");
    } catch (e) {
      showModalError(e.message);
    }
  };

  document.getElementById("closeLoginRequired").onclick = () => {
    document.getElementById("loginRequiredModal").classList.remove("active");
  };

  document.getElementById("goToLoginBtn").onclick = () => {
    document.getElementById("loginRequiredModal").classList.remove("active");
    openModal(true);
  };

  document.getElementById("goToRegisterBtn").onclick = () => {
    document.getElementById("loginRequiredModal").classList.remove("active");
    openModal(false);
  };

  document.querySelectorAll(".star").forEach((star) => {
    star.addEventListener("click", () => {
      rating = parseInt(star.dataset.value);
      document.querySelectorAll(".star").forEach((s) => {
        s.classList.toggle("active", parseInt(s.dataset.value) <= rating);
      });
    });
  });

  document.getElementById("generateBtn").onclick = generateReply;
  updateGuestCounter();
});

/* ===================== */
/* MODAL ERROR MESSAGE */
/* ===================== */
function showModalError(msg) {
  let err = document.getElementById("modalError");
  if (!err) {
    err = document.createElement("p");
    err.id = "modalError";
    err.style.cssText =
      "color:#f87171;font-size:13px;margin-top:10px;text-align:center;";
    document.querySelector(".modal-body").appendChild(err);
  }
  err.textContent = msg;
  setTimeout(() => {
    err.textContent = "";
  }, 4000);
}

/* ===================== */
/* SUCCESS MESSAGE */
/* ===================== */
function showSuccessMessage(text) {
  const box = document.getElementById("successModal");
  const inner = box.querySelector(".success-box");
  inner.textContent = text;
  box.classList.add("active");
  setTimeout(() => box.classList.remove("active"), 2500);
}

/* ===================== */
/* REPLY GENERATOR */
/* ===================== */
async function generateReply() {
  const review = document.getElementById("reviewInput").value.trim();
  const tone = document.getElementById("toneSelect").value;
  const output = document.getElementById("outputBox");
  const loading = document.getElementById("loading");

  if (!review) return alert("Please paste a review first.");

  // Guest user - check limit
  if (!currentUser) {
    const count = getGuestCount();
    if (count >= FREE_LIMIT) {
      // Show register modal
      document.getElementById("loginRequiredModal").classList.add("active");
      // Update modal text
      const modal = document.getElementById("loginRequiredModal");
      const h2 = modal.querySelector("h2");
      const p = modal.querySelector(".modal-subtitle");
      if (h2) h2.textContent = "You've used all 6 free replies!";
      if (p) p.textContent = "Register for free to get more replies.";
      return;
    }
  }

  if (currentUser && !userData)
    return alert("User data not loaded, please try again.");

  loading.style.display = "block";
  output.textContent = "";

  try {
    const res = await fetch(
      "https://reviewreply-production-c63d.up.railway.app/api/reply",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          review,
          rating,
          tone,
          lang: window.currentLang || "en",
          uid: currentUser?.uid || null,
        }),
      },
    );

    const data = await res.json();
    output.textContent = data.reply || "No response received.";

    // Increment guest count after successful reply
    if (!currentUser) {
      incrementGuestCount();
      updateGuestCounter();
    }
  } catch (err) {
    output.textContent = "Error connecting to server.";
  } finally {
    loading.style.display = "none";
  }
}

/* ===================== */
/* COPY */
/* ===================== */
window.copyReply = function () {
  const text = document.getElementById("outputBox").textContent;
  navigator.clipboard.writeText(text);
};

/* ===================== */
/* PRICING */
/* ===================== */
window.selectPlan = function (plan) {
  currentPlan = plan;
  document
    .querySelectorAll(".pricing-card")
    .forEach((c) => c.classList.remove("popular"));
  document.querySelector(`.pricing-card.${plan}`)?.classList.add("popular");
};

window.checkout = async function (plan) {
  if (!currentUser) {
    document.getElementById("loginRequiredModal").classList.add("active");
    return;
  }

  const res = await fetch(
    "https://reviewreply-production-c63d.up.railway.app/create-checkout-session",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        plan,
        uid: currentUser.uid,
        email: currentUser.email,
      }),
    },
  );

  const data = await res.json();
  if (data.url) window.location.href = data.url;
};
