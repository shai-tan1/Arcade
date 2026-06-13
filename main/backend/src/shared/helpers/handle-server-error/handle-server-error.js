import {
    PRODUCTION_STATUS
} from "../../../shared/constants/index.js";

export const handleServerError = (res, error, context = null) => {
    if (!context) {
        const stack = new Error().stack;
        context = stack?.split('\n')[2]?.match(/at (\w+)/)?.[1] || "UnknownContext";
    }

    console.error(`❌ ${context}:`, error);

    if (PRODUCTION_STATUS) {
        return res.status(500).json({ message: "Server error" });
    }
    else {
        return res.status(500).json({
            message: "Server error",
            error: {
                message: error.message,
                stack: error.stack,
                context,
            },
        });
    }
};
