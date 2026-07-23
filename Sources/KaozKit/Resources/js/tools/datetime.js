// current_datetime — the current moment in ISO 8601 with the local timezone
// offset. Pure JS, no native dependency beyond Date.
function localISO(d) {
  const pad = (n) => String(n).padStart(2, "0");
  const off = -d.getTimezoneOffset(); // minutes east of UTC
  const sign = off >= 0 ? "+" : "-";
  const oh = pad(Math.floor(Math.abs(off) / 60));
  const om = pad(Math.abs(off) % 60);
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds())
    + sign + oh + ":" + om;
}

export default {
  name: "current_datetime",
  description:
    "Returns the current date and time in ISO 8601 format, including the local "
    + "timezone offset. Use this whenever an answer depends on the current moment "
    + "(today's date, day of week, time until/since an event). Takes no arguments.",
  input_schema: { type: "object", properties: {}, additionalProperties: false },
  run() {
    return localISO(new Date());
  },
};
