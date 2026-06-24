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

  if (user) {
    logoutBtn.style.display = "inline-block";

    const ref = doc(db, "users", user.uid);
    const snap = await getDoc(ref);

    if (snap.exists()) userData = snap.data();
  } else {
    logoutBtn.style.display = "none";
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
        await signInWithEmailAndPassword(auth, email, password);
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
