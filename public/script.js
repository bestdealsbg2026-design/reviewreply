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
    // When in login mode → show "Don't have an account? Register"
    switchText.childNodes[0].textContent = "Don't have an account? ";
    switchLink.textContent = "Register";
  } else {
    title.textContent = "Create Account";
    authBtn.textContent = "Create Account";
    // When in register mode → show "Already have an account? Log in"
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

  // Close main modal
  closeBtn.onclick = () => modal.classList.remove("active");

  // Enter key submits the form
  document.getElementById("registerModal").addEventListener("keydown", (e) => {
    if (e.key === "Enter") authBtn.click();
  });

  // Switch between login / register inside modal
  switchLink.onclick = () => {
    isLoginMode = !isLoginMode;
    updateModalUI();
  };

  // Auth submit
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

  // Login Required modal buttons
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

  // Stars
  document.querySelectorAll(".star").forEach((star) => {
    star.addEventListener("click", () => {
      rating = parseInt(star.dataset.value);
      document.querySelectorAll(".star").forEach((s) => {
        s.classList.toggle("active", parseInt(s.dataset.value) <= rating);
      });
    });
  });

  // Generate button
  document.getElementById("generateBtn").onclick = generateReply;
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
  // Not logged in → show nice modal instead of alert
  if (!currentUser) {
    document.getElementById("loginRequiredModal").classList.add("active");
    return;
  }

  if (!userData) return alert("User data not loaded, please try again.");

  const review = document.getElementById("reviewInput").value.trim();
  const tone = document.getElementById("toneSelect").value;
  const output = document.getElementById("outputBox");
  const loading = document.getElementById("loading");

  if (!review) return alert("Please paste a review first.");

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
        }),
      },
    );

    const data = await res.json();
    output.textContent = data.reply || "No response received.";
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
